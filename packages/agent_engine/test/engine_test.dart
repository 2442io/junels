// Ohne package:test lauffähige Tests (nur Dart SDK nötig).
//
//   AE_LIB_PATH=/pfad/libagent_engine.so AE_TEST_MODEL=/pfad/modell.gguf \
//     dart run test/engine_test.dart
//
// Ohne AE_TEST_MODEL laufen nur die Tests ohne Modell.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';
import 'package:agent_engine/src/sync/sync_crypto.dart' show hmacSha256, pbkdf2, chacha20;

var _failed = 0;
var _passed = 0;

void check(bool cond, String what) {
  if (cond) {
    _passed++;
    print('  ok   $what');
  } else {
    _failed++;
    print('  FAIL $what');
  }
}

Future<void> group(String name, Future<void> Function() body) async {
  print('\n$name');
  try {
    await body();
  } catch (e, st) {
    _failed++;
    print('  FAIL Ausnahme: $e\n$st');
  }
}

Future<void> main() async {
  final envModel = Platform.environment['AE_TEST_MODEL'] ?? '';
  final modelPath = envModel.isEmpty ? null : envModel;

  await group('Agent-Plattformen', () async {
    final dify = jsonDecode(platformRequestBody(AgentPlatform.dify, Uri.parse('https://api.dify.ai/v1/workflows/run'), 'Hallo', inputKey: 'text')) as Map;
    check(dify['inputs']['text'] == 'Hallo' && dify['response_mode'] == 'blocking', 'Dify-Workflow: inputs');
    final difyChat = jsonDecode(platformRequestBody(AgentPlatform.dify, Uri.parse('https://api.dify.ai/v1/chat-messages'), 'Hi')) as Map;
    check(difyChat['query'] == 'Hi', 'Dify-Chat: query');
    check((jsonDecode(platformRequestBody(AgentPlatform.flowise, Uri.parse('https://x/api/v1/prediction/1'), 'F')) as Map)['question'] == 'F', 'Flowise: question');
    check((jsonDecode(platformRequestBody(AgentPlatform.n8n, Uri.parse('https://x/webhook/a'), 'N', meta: {'prozess': 'P'})) as Map)['prozess'] == 'P', 'n8n: Zusatzangaben');
    check(platformAnswer(AgentPlatform.dify, '{"data": {"outputs": {"result": "Fertig"}}}') == 'Fertig', 'Dify-Antwort');
    check(platformAnswer(AgentPlatform.dify, '{"answer": "Chat-Antwort"}') == 'Chat-Antwort', 'Dify-Chat-Antwort');
    check(platformAnswer(AgentPlatform.flowise, '{"text": "Flow"}') == 'Flow', 'Flowise-Antwort');
    check(platformAnswer(AgentPlatform.langflow, '{"outputs":[{"outputs":[{"results":{"message":{"text":"LF"}}}]}]}') == 'LF', 'Langflow-Antwort');
    check(platformAnswer(AgentPlatform.n8n, '[{"output": "aus n8n"}]') == 'aus n8n', 'n8n-Antwort in Liste');
    check(platformAnswer(AgentPlatform.webhook, 'nur Text') == 'nur Text', 'Text bleibt Text');
    check(platformAnswer(AgentPlatform.webhook, '{"a": 1, "b": 2}').contains('"b": 2'), 'unbekanntes JSON eingerückt');
    check(teamVerdict('OK\nSieht gut aus').$1, 'Prüfer: OK');
    check(teamVerdict('Freigegeben.').$1, 'Prüfer: freigegeben');
    final v = teamVerdict('ÜBERARBEITEN: Quellen fehlen');
    check(!v.$1 && v.$2 == 'Quellen fehlen', 'Prüfer: Rückmeldung');
  });

  await group('Junels als MCP-Server', () async {
    final core = McpServeCore(name: 'junels', version: '1', tools: () => [
          ServedTool('skill_bericht', 'Bericht schreiben', {'type': 'object'}, (a) async => 'Bericht zu ${a['aufgabe']}'),
          ServedTool('kaputt', 'wirft', {'type': 'object'}, (a) async => throw Exception('geht nicht')),
        ]);
    final init = await core.handle({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-03-26'}}) as Map;
    check(init['result']['protocolVersion'] == '2025-03-26' && init['result']['capabilities']['tools'] != null, 'initialize');
    check(await core.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}) == null, 'Benachrichtigung ohne Antwort');
    final list = await core.handle({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}) as Map;
    check((list['result']['tools'] as List).length == 2, 'tools/list');
    final call = await core.handle({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'skill_bericht', 'arguments': {'aufgabe': 'Q3'}}}) as Map;
    check(call['result']['content'][0]['text'] == 'Bericht zu Q3' && call['result']['isError'] == false, 'tools/call');
    final bad = await core.handle({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'kaputt'}}) as Map;
    check(bad['result']['isError'] == true && bad['result']['content'][0]['text'] == 'geht nicht', 'Fehler als isError');
    final unk = await core.handle({'jsonrpc': '2.0', 'id': 5, 'method': 'gibtsnicht'}) as Map;
    check(unk['error']['code'] == -32601, 'unbekannte Methode');
    final batch = await core.handle([{'jsonrpc': '2.0', 'id': 6, 'method': 'ping'}, {'jsonrpc': '2.0', 'method': 'x'}]) as List;
    check(batch.length == 1, 'Stapel');
    check(McpServeCore.safeName('Tagesüberblick heute!') == 'tagesueberblick_heute', 'sichere Namen');
    check(McpServeCore.originAllowed(null) && McpServeCore.originAllowed('http://localhost:3000') && !McpServeCore.originAllowed('https://evil.example'), 'Origin-Schutz');
  });

  await group('Kalender-Abo (iCal)', () async {
    const ics = 'BEGIN:VCALENDAR\r\nX-WR-CALNAME:Christoph\r\n'
        'BEGIN:VEVENT\r\nDTSTART;TZID=Europe/Vienna:20261123T110000\r\nDTEND;TZID=Europe/Vienna:20261123T120000\r\n'
        'SUMMARY:Dawin krallen Termin anrufen\r\nEND:VEVENT\r\n'
        'BEGIN:VEVENT\r\nDTSTART:20261123T150000Z\r\nDTEND:20261123T160000Z\r\nSUMMARY:Chatbot Event\r\nLOCATION:Wien\\, Austria\r\nEND:VEVENT\r\n'
        'BEGIN:VEVENT\r\nDTSTART;VALUE=DATE:19900324\r\nDTEND;VALUE=DATE:19900325\r\nRRULE:FREQ=YEARLY\r\nSUMMARY:Geburtstag Dominik\r\nEND:VEVENT\r\n'
        'BEGIN:VEVENT\r\nDTSTART;TZID=Europe/Vienna:20261102T090000\r\nDTEND;TZID=Europe/Vienna:20261102T093000\r\n'
        'RRULE:FREQ=WEEKLY;BYDAY=MO,WE\r\nEXDATE;TZID=Europe/Vienna:20261125T090000\r\nSUMMARY:Standup\r\nEND:VEVENT\r\n'
        'BEGIN:VEVENT\r\nDTSTART:20261124T080000\r\nDTEND:20261124T090000\r\nSUMMARY:Reifenwechseln\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n'
        'END:VCALENDAR\r\n';
    final day = parseIcs(ics, DateTime(2026, 11, 23), DateTime(2026, 11, 24));
    check(day.map((e) => e.title).toList().toString() == '[Standup, Dawin krallen Termin anrufen, Chatbot Event]',
        'Tag: Serie, lokaler und UTC-Termin (${day.map((e) => e.title).toList()})');
    check(day.first.begin.hour == 9 && day[1].begin.hour == 11, 'Uhrzeiten lokal');
    check(day.last.location == 'Wien, Austria' && day.last.calendar == 'Christoph', 'Ort entschlüsselt, Kalendername');
    final wed = parseIcs(ics, DateTime(2026, 11, 25), DateTime(2026, 11, 26));
    check(wed.isEmpty, 'EXDATE nimmt den Mittwoch raus');
    final bday = parseIcs(ics, DateTime(2027, 3, 24), DateTime(2027, 3, 25)).where((e) => e.title.startsWith('Geburtstag')).toList();
    check(bday.length == 1 && bday.first.allDay, 'Jährlicher Geburtstag (ganztägig)');
    check(parseIcs(ics, DateTime(2027, 3, 23), DateTime(2027, 3, 24)).every((e) => !e.title.startsWith('Geburtstag')),
        'Geburtstag nicht am Vortag');
    check(parseIcs(ics, DateTime(2026, 11, 24), DateTime(2026, 11, 25)).isEmpty, 'Abgesagter Termin fehlt');
  });

  await group('Rechner', () async {
    double c(String e) => CalculatorTool.evaluate(e);
    check(c('(3+4)*2') == 14, '(3+4)*2 = 14');
    check(c('2^3^2') == 512, 'Potenz rechtsassoziativ');
    check(c('-2^2') == -4, 'Vorzeichen');
    check(c('sqrt(16) + abs(-3)') == 7, 'Funktionen');
    check(c('max(1, 5, 3)') == 5, 'max mit mehreren Argumenten');
    check((c('round(pi, 2)') - 3.14).abs() < 1e-9, 'round mit Stellen');
    check(c('10 % 3') == 1, 'Modulo');
    check(c('1,5 * 2') == 3, 'Komma als Dezimaltrenner');
    check(c('1e3 + 1') == 1001, 'Exponentschreibweise');
    check(CalculatorTool.format(0.1 + 0.2) == '0.3', 'Formatierung 0.1+0.2');
    var threw = false;
    try {
      c('2 +');
    } on ToolException {
      threw = true;
    }
    check(threw, 'unvollständiger Ausdruck wirft');
    threw = false;
    try {
      c('system("rm")');
    } on ToolException {
      threw = true;
    }
    check(threw, 'unbekannte Funktion wirft');
  });

  await group('JSON-Abfrage', () async {
    const data = {
      'items': [
        {'name': 'A', 'price': 2},
        {'name': 'B', 'price': 5}
      ],
      'meta': {'total count': 2}
    };
    check(JsonQueryTool.query(data, 'items[1].name') == 'B', 'Index + Feld');
    check((JsonQueryTool.query(data, 'items[*].price') as List).join(',') == '2,5', 'Platzhalter');
    check(JsonQueryTool.query(data, 'meta["total count"]') == 2, 'Schlüssel mit Leerzeichen');
    check(JsonQueryTool.query(data, '') == data, 'leerer Pfad = alles');
    final ctx = ToolContext(attachments: [
      const Attachment(name: 'daten.json', content: '{"a": {"b": [1, 2, 3]}}')
    ]);
    final r = await JsonQueryTool().run({'source': 'daten.json', 'path': 'a.b[2]'}, ctx);
    check(r.trim() == '3', 'Abfrage auf Anhang');
  });

  await group('Datei-Tools', () async {
    final long = List.generate(400, (i) => 'Zeile $i: Inhalt ${i % 7 == 0 ? 'Rechnung' : 'Text'}').join('\n');
    final ctx = ToolContext(attachments: [Attachment(name: 'notizen.txt', content: long)]);
    final r1 = await ReadFileTool().run({'name': 'notizen.txt', 'start': 0}, ctx);
    check(r1.contains('weiter mit start=3000'), 'read_file liefert Abschnitt mit Fortsetzung');
    final r2 = await ReadFileTool().run({'name': 'NOTIZEN', 'start': 999999}, ctx);
    check(r2.contains('Ende der Datei'), 'read_file Ende, unscharfer Name');
    final s = await TextSearchTool().run({'query': 'Rechnung'}, ctx);
    check(s.startsWith('58 Treffer'), 'text_search zählt Treffer ($s)'.split('\n').first);
    final none = await TextSearchTool().run({'query': 'xyzzy'}, ctx);
    check(none.contains('Keine Treffer'), 'text_search ohne Treffer');
    final arts = <Artifact>[];
    final ctx2 = ToolContext(onArtifact: arts.add);
    await WriteArtifactTool().run({'title': 'Plan', 'kind': 'markdown', 'content': '# Hi'}, ctx2);
    check(arts.length == 1 && arts.first.kind == 'markdown', 'write_artifact erzeugt Artefakt');
    final dt = await DateTimeTool().run({}, ToolContext(clock: () => DateTime(2026, 11, 18, 19, 5)));
    check(dt.startsWith('Mittwoch, 18.11.2026, 19:05'), 'datetime ($dt)');
  });

  await group('Teil-JSON aus Stream', () async {
    check(extractPartialJsonString('{"thought": "Ich rech', 'thought') == 'Ich rech', 'unvollständiger String');
    check(extractPartialJsonString('{"thought": "a\\nb\\"c", "x"', 'thought') == 'a\nb"c', 'Escapes');
    check(extractPartialJsonString('{"thought": "x"', 'final_answer') == null, 'Schlüssel fehlt');
    check(extractPartialJsonString('{"final_answer":"\\u00e4"}', 'final_answer') == 'ä', 'Unicode-Escape');
  });

  await group('Grammatik-Text', () async {
    final g = AgentGrammar.build(builtinTools());
    check(g.contains('tool-text-search ::= "\\"text_search\\""'), 'Tool-Regel mit Literal');
    check(g.contains('( "\\"code\\"" | "\\"markdown\\""'), 'Enum-Werte als Alternativen');
    check(g.contains(r'\u4E00-\u9FFF') && !AgentGrammar.build(builtinTools(), blockCjk: false).contains(r'\u4E00'),
        'CJK-Sperre in Strings (abschaltbar)');
    final f = AgentGrammar.build(builtinTools(), allowTools: false);
    check(f.contains('step ::= final') && !f.contains('call ::='), 'Nur-Endantwort-Variante');
  });

  await group('Geräteprofil', () async {
    final s = DeviceProfile.detect(totalMemoryOverride: 4 * 1024 * 1024 * 1024, cpuOverride: 8);
    check(s.deviceClass == DeviceClass.s && s.maxContext == 2048, 'Klasse S bei 4 GB');
    final m = DeviceProfile.detect(totalMemoryOverride: 8 * 1024 * 1024 * 1024, cpuOverride: 8);
    check(m.deviceClass == DeviceClass.m && m.maxContext == 4096, 'Klasse M bei 8 GB');
    final l = DeviceProfile.detect(totalMemoryOverride: 16 * 1024 * 1024 * 1024, cpuOverride: 10);
    check(l.deviceClass == DeviceClass.l && l.threads == 8, 'Klasse L bei 16 GB, 8 Threads');
  });

  await group('GGUF-Kopf', () async {
    final bad = File('${Directory.systemTemp.path}/kein_modell.gguf')..writeAsStringSync('hallo welt');
    var threw = false;
    try {
      await GgufInfo.read(bad.path);
    } on GgufFormatException {
      threw = true;
    }
    check(threw, 'falsche Datei wird abgelehnt');
    if (modelPath == null) return;
    final info = await GgufInfo.read(modelPath);
    print('  info: ${info.architecture}, ${info.name}, ${info.quantization}, ctx ${info.contextLength}, '
        'Schichten ${info.blockCount}, KV-Köpfe ${info.headCountKv}');
    check(info.architecture.isNotEmpty && info.architecture != '?', 'Architektur gelesen');
    check((info.contextLength ?? 0) > 0, 'Kontextlänge gelesen');
    check(info.estimateKvCacheBytes(2048) > 0, 'KV-Schätzung > 0');
    final p = DeviceProfile.detect();
    final fit = p.checkFit(info, 2048);
    print('  fit: ${fit.level} ${fit.message}');
    check(fit.level != FitLevel.refuse, 'Testmodell passt in den Speicher');
    final tiny = DeviceProfile.detect(totalMemoryOverride: 1024 * 1024 * 1024);
    final huge = tiny.checkFit(
        GgufInfo(path: 'x', fileSize: 5 * 1024 * 1024 * 1024, version: 3, tensorCount: 0, metadata: info.metadata),
        2048,
        availableOverride: 512 * 1024 * 1024);
    check(huge.level == FitLevel.refuse, '5-GB-Modell wird auf 1-GB-Gerät abgelehnt');
  });

  await group('Automatische Modellwahl', () async {
    bool cx(String s, {int docs = 0, bool prev = false}) => assessTask(s, docChars: docs, previousComplex: prev).complex;
    check(!cx('Hallo, wie geht es dir?') && !cx('Wie wird das Wetter morgen in Wien?') && !cx('Was ist 15 % von 2340?'),
        'Alltagsfragen → schnelles Modell');
    check(!cx('Wer ist der Bürgermeister von Graz?') && !cx('Stell einen Timer auf 10 Minuten'), 'kurze Fakten → schnell');
    check(cx('Analysiere die Vor- und Nachteile von On-Prem- gegenüber Cloud-KI für eine Behörde und gib eine Empfehlung.'),
        'Analyse → starkes Modell (${assessTask('Analysiere die Vor- und Nachteile von On-Prem- gegenüber Cloud-KI')})');
    check(cx('Schreib mir ein Python-Skript, das alle PDFs in einem Ordner umbenennt'), 'Code → stark');
    check(cx('Erstelle eine Präsentation mit 8 Folien über lokale KI im Unternehmen'), 'Präsentation → stark');
    check(cx('Fasse das zusammen', docs: 12000), 'langes Dokument → stark');
    check(cx('und was ist mit den Kosten?', prev: true) && !cx('und was ist mit den Kosten?'), 'Nachfrage bleibt beim starken Modell');
    check(cx('1. Ziele festlegen\n2. Budget prüfen\n3. Team planen\nWie gehe ich vor?'), 'mehrteiliger Auftrag → stark');
    check(cx('Warum ist der Himmel blau? Und warum sind Sonnenuntergänge rot?'), 'Erklärung mit Folgefragen → stark');

    const gb = 1 << 30;
    final meta = <String, Object>{
      'general.architecture': 'llama',
      'llama.block_count': 32,
      'llama.attention.head_count': 32,
      'llama.attention.head_count_kv': 8,
      'llama.embedding_length': 4096,
      'llama.context_length': 8192,
    };
    GgufInfo m(int size) => GgufInfo(path: 'x', fileSize: size, version: 3, tensorCount: 0, metadata: meta);
    final big = DeviceProfile.detect(totalMemoryOverride: 32 * gb);
    final p1 = planResidency(big, m(2 * gb), 4096, m(7 * gb), 4096, available: 24 * gb);
    check(p1.residency == Residency.both, 'Mac mit 32 GB: beide geladen (${p1.message})');
    final phone = DeviceProfile.detect(totalMemoryOverride: 8 * gb);
    final p2 = planResidency(phone, m(2 * gb), 4096, m(3 * gb), 4096, available: 5 * gb);
    check(p2.residency == Residency.swap, 'Handy mit 8 GB: Wechsel bei Bedarf (${p2.message})');
    final p3 = planResidency(phone, m(2 * gb), 4096, m(9 * gb), 4096, available: 5 * gb);
    check(p3.residency == Residency.fastOnly, 'zu großes Modell: nur das schnelle');
    final pair = pickModelPair<int>([3, 9, 5], (x) => x);
    check(pair != null && pair.$1 == 3 && pair.$2 == 9, 'Paar: kleinstes + größtes');
    check(pickModelPair<int>([4, 5], (x) => x) == null, 'ähnlich große Modelle: keine Auswahl');
    check(pickModelPair<int>([3, 9, 20], (x) => x, fits: (x) => x < 10)!.$2 == 9, 'nur Modelle, die passen');
  });

  await group('Kommentar während der Arbeit', () async {
    // Agenten-Modus: Kommentar während eines Werkzeugs → nächster Schritt sieht ihn
    final slowTool = _SlowTool();
    final b = ScriptedBackend([
      '{"thought": "Ich suche.", "action": "slow", "args": {"q": "Hotels Wien"}}',
      '{"thought": "fertig", "final_answer": "Hotels unter 150 €: A, B"}',
    ]);
    final runner = AgentRunner(engine: b, systemPrompt: 'Test', tools: [slowTool], maxSteps: 4);
    final events = <AgentEvent>[];
    final done = runner.run(history: const [], userInput: 'Suche Hotels in Wien', context: ToolContext()).forEach(events.add);
    await slowTool.started.future;
    check(runner.addNote('bitte nur unter 150 €'), 'Kommentar angenommen');
    slowTool.release.complete();
    await done;
    check(events.whereType<NoteApplied>().single.text == 'bitte nur unter 150 €', 'Kommentar als Ereignis');
    check(b.prompts.last.contains('Ergänzung des Nutzers') && b.prompts.last.contains('unter 150 €'), 'Modell bekommt den Kommentar');
    check(!runner.addNote('zu spät') && runner.pendingNotes.isEmpty, 'nach dem Ende nicht mehr angenommen');

    // Chat-Modus: Kommentar während der Ausgabe → Ausgabe wird abgebrochen und überarbeitet
    final slow = _SlowBackend(['Erster Entwurf über Wien mit vielen Details …', 'Kurze Fassung über Wien.']);
    final chat = AgentRunner(engine: slow, systemPrompt: 'Test', tools: const []);
    final ev2 = <AgentEvent>[];
    final d2 = chat.run(history: const [], userInput: 'Erzähl mir etwas über Wien', context: ToolContext()).forEach(ev2.add);
    await slow.firstToken.future;
    chat.addNote('bitte kürzer');
    await d2;
    check(slow.stops == 1 && slow.prompts.length == 2, 'laufende Ausgabe abgebrochen und neu begonnen');
    check(slow.prompts.last.contains('bitte kürzer') && ev2.whereType<FinalAnswer>().single.text == 'Kurze Fassung über Wien.',
        'Antwort berücksichtigt den Kommentar');
  });

  await group('Agent: Tool-Ablauf (gescriptet)', () async {
    final backend = ScriptedBackend([
      '{"thought": "Ich rechne.", "action": "calculator", "args": {"expression": "17*23"}}',
      '{"thought": "Nochmal.", "action": "calculator", "args": {"expression": "17*23"}}',
      '{"thought": "Ich suche.", "action": "text_search", "args": {"query": "Budget"}}',
      '{"thought": "Unbekannt.", "action": "nope", "args": {}}',
      '{"thought": "Fertig.", "final_answer": "17 × 23 = **391**"}',
    ]);
    final runner = AgentRunner(engine: backend, systemPrompt: 'Test', tools: builtinTools(), maxSteps: 6);
    final events = await runner
        .run(
            history: const [ChatMessage('user', 'vorher'), ChatMessage('assistant', 'ok')],
            userInput: 'Was ist 17*23?',
            context: ToolContext(attachments: const [Attachment(name: 'b.txt', content: 'Budget 2026: 500 €')]))
        .toList();
    final results = events.whereType<ToolResult>().toList();
    check(results.length == 4, '4 Tool-Ergebnisse (${results.length})');
    check(results[0].output == '17*23 = 391' && !results[0].isError, 'calculator liefert 391');
    check(results[1].isError && results[1].output.contains('gerade'), 'Wiederholung wird erkannt');
    check(results[2].output.contains('b.txt:1'), 'text_search findet Anhang');
    check(results[3].isError && results[3].output.contains('Unbekanntes Tool'), 'unbekanntes Tool abgefangen');
    final fa = events.whereType<FinalAnswer>().single;
    check(fa.text == '17 × 23 = **391**' && fa.thought == 'Fertig.', 'Endantwort mit Gedanke');
    check(events.whereType<AgentFinished>().single.reason == AgentStopReason.answered, 'Grund answered');
    check(backend.prompts.last.contains('Beobachtung (calculator):\n17*23 = 391'), 'Beobachtung im Prompt');
    check(backend.prompts.first.contains('<user>vorher'), 'Verlauf im Prompt');
    check(backend.grammars.every((g) => g != null && g.contains('tool-calculator')), 'Grammatik mit Tools');
    final streamed = events.whereType<StepStreaming>().where((e) => e.thought != null).toList();
    check(streamed.isNotEmpty && streamed.first.thought!.length < 'Ich rechne.'.length, 'Gedanke wird live gestreamt');
  });

  await group('Sprache erkennen', () async {
    check(detectLanguage('Regarde sur Internet quels sont les tarifs actuels pour les vols de Vienne à Toulouse.') == 'fr', 'Französisch');
    check(detectLanguage('What are the current prices for flights from Vienna to Toulouse?') == 'en', 'Englisch');
    check(detectLanguage('Was kosten aktuell Flüge von Wien nach Toulouse?') == 'de', 'Deutsch');
    check(detectLanguage('Cerca i prezzi dei voli da Vienna a Tolosa') == 'it', 'Italienisch');
    check(detectLanguage('Hallo') == null, 'zu kurz: keine Vorgabe');
  });

  await group('Posteingang (IMAP, nur lesend)', () async {
    check(decodeMimeWords('=?UTF-8?B?UHLDpHNlbnRhdGlvbg==?= fertig') == 'Präsentation fertig' &&
        decodeMimeWords('=?ISO-8859-1?Q?Gr=FC=DFe_aus_Wien?=') == 'Grüße aus Wien', 'MIME-Betreffs dekodiert');
    check(ImapAccount.guessHost('max@gmail.com') == 'imap.gmail.com' && ImapAccount.guessHost('a@firma.at', smtpHost: 'smtp.firma.at') == 'imap.firma.at',
        'IMAP-Server abgeleitet');
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final cmds = <String>[];
    server.listen((sock) {
      sock.write('* OK IMAP4rev1 bereit\r\n');
      sock.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        cmds.add(line);
        final tag = line.split(' ').first;
        final c = line.substring(tag.length + 1);
        if (c.startsWith('LOGIN')) {
          sock.write(c.contains('"falsch"') ? '$tag NO [AUTHENTICATIONFAILED] Invalid credentials\r\n' : '$tag OK eingeloggt\r\n');
        } else if (c.startsWith('EXAMINE')) {
          sock.write('* 3 EXISTS\r\n$tag OK [READ-ONLY] EXAMINE fertig\r\n');
        } else if (c.startsWith('UID SEARCH')) {
          sock.write('* SEARCH 11 12 13\r\n$tag OK SEARCH fertig\r\n');
        } else if (c.startsWith('UID FETCH')) {
          String msg(int n, String flags, String hdr) {
            final body = '$hdr\r\n\r\n';
            return '* $n FETCH (UID ${10 + n} FLAGS ($flags) BODY[HEADER.FIELDS (FROM SUBJECT DATE)] {${utf8.encode(body).length}}\r\n$body)\r\n';
          }
          sock.write(msg(1, r'\Seen', 'From: "Anna Huber" <anna@firma.at>\r\nSubject: =?UTF-8?B?QW5nZWJvdCBmw7xyIGRpZSBSZWlzZQ==?=\r\nDate: Thu, 19 Nov 2026 09:12:00 +0100'));
          sock.write(msg(2, '', 'From: Newsletter <news@shop.at>\r\nSubject: Rabatt!\r\nList-Unsubscribe: <mailto:x@shop.at>\r\nDate: Fri, 20 Nov 2026 10:00:00 +0100'));
          sock.write(msg(3, '', 'From: Chef <chef@firma.at>\r\nSubject: Termin\r\n Montag?\r\nDate: Sat, 21 Nov 2026 18:30:00 +0100'));
          sock.write('$tag OK FETCH fertig\r\n');
        } else if (c.startsWith('LOGOUT')) {
          sock.write('* BYE\r\n$tag OK tschüss\r\n');
          sock.close();
        }
      });
    });
    final acc = ImapAccount(host: '127.0.0.1', port: server.port, user: 'ich@firma.at', password: 'geheim', secure: false);
    final mails = await fetchInbox(acc, days: 7, unansweredOnly: true, now: DateTime(2026, 11, 22));
    check(mails.length == 3 && mails.first.from == 'Chef' && mails.first.subject == 'Termin Montag?' && mails.last.subject == 'Angebot für die Reise',
        'Kopfzeilen gelesen, neueste zuerst');
    check(mails[1].bulk && !mails.first.seen && mails.last.seen, 'Newsletter und Gelesen-Status erkannt');
    check(cmds.any((c) => c.contains('EXAMINE INBOX')) && cmds.any((c) => c.contains('UNANSWERED') && c.contains('SINCE 15-Nov-2026')) &&
        cmds.any((c) => c.contains('BODY.PEEK')) && !cmds.any((c) => c.contains('STORE') || c.contains('SELECT')),
        'nur lesend (EXAMINE, BODY.PEEK, kein STORE)');
    final out = await MailInboxTool(() async => acc).run({'filter': 'unbeantwortet', 'tage': 7}, ToolContext(requestNetwork: (_) async => true));
    check(out.contains('Chef') && out.contains('Angebot') && !out.contains('Rabatt') && out.contains('1 Newsletter'), 'Werkzeug blendet Newsletter aus');
    var err = '';
    try {
      await fetchInbox(ImapAccount(host: '127.0.0.1', port: server.port, user: 'ich', password: 'falsch', secure: false));
    } catch (e) {
      err = '$e';
    }
    check(err.contains('Anmeldung'), 'falsches Passwort: verständlicher Fehler');
    await server.close();
  });

  await group('Eigene Designs', () async {
    final sample = buildPptx(title: 'CI', slides: splitSlides('# A\n- x').slides, design: designById('business'));
    final made = await designFromSample(sample, 'Firma.pptx', name: 'Firmen-CI');
    check(made != null && made.$1.id == 'eigen-firmen-ci' && made.$1.primary == '1F3A60' && made.$2 != null, 'Design aus PowerPoint angelegt');
    final tplFile = File('${Directory.systemTemp.createTempSync('ci').path}/ci.pptx')..writeAsBytesSync(made!.$2!);
    DesignLibrary.user
      ..clear()
      ..add(UserDesign(design: made.$1, templatePath: tplFile.path));
    DesignLibrary.defaultId = made.$1.id;
    final look = await resolveDesign(ctx: ToolContext()..userRequest = 'Präsentation über unsere Reise', topic: 'Reise');
    check(look.design.id == 'eigen-firmen-ci' && look.template != null, 'Standard-Design gilt (statt Reise-Design), mit Folienmaster');
    final ex = await resolveDesign(ctx: ToolContext()..userRequest = 'Präsentation über unsere Reise', topic: 'Reise', design: 'reise');
    check(ex.design.id == 'reise', 'Ausdrücklich gewählter Stil geht vor');
    DesignLibrary.defaultId = null;
    final byName = await resolveDesign(ctx: ToolContext()..userRequest = 'Mach das im Firmen-CI', topic: 'x');
    check(byName.design.id == 'eigen-firmen-ci', 'Design per Name im Auftrag');
    check(CreatePresentationTool(OutputSpace(Directory.systemTemp)).params[2].values.contains('eigen-firmen-ci'), 'Eigenes Design im Werkzeug wählbar');
    DesignLibrary.user.clear();
  });

  await group('Dateien gezielt ändern', () async {
    final dir = Directory.systemTemp.createTempSync('edit');
    final out = OutputSpace(dir);
    final made = <String>[];
    final ctx = ToolContext(onArtifact: (a) => made.add(a.title));
    await CreatePresentationTool(out).run({
      'title': 'Reise nach Lissabon',
      'content': 'Unser Plan\n# Anreise\n- Flug\n# Tag 1\n- Alfama\n# Tag 2\n- Belém\n# Heimreise\n- Rückflug',
      'design': 'reise',
      'vorlage': '',
    }, ctx);
    final edit = EditFileTool(out);
    final ov = await edit.run({'aktion': 'anzeigen', 'datei': '', 'folie': 0, 'abschnitt': '', 'inhalt': ''}, ctx);
    check(ov.contains('1. Reise nach Lissabon (Titel)') && ov.contains('2. Reiseroute') && ov.contains('4. Tag 1'), 'Übersicht mit Foliennummern: $ov');
    final show = await edit.run({'aktion': 'anzeigen', 'datei': '', 'folie': 4, 'abschnitt': '', 'inhalt': ''}, ctx);
    check(show.contains('# Tag 1') && show.contains('Alfama'), 'Folie 4 lesen');
    final r = await edit.run({'aktion': 'ersetzen', 'datei': '', 'folie': 4, 'abschnitt': '', 'inhalt': '# Tag 1: Altstadt\n- Alfama\n- Fado am Abend'}, ctx);
    final pptx = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.pptx')).toList();
    final txt = officeText(pptx.single.readAsBytesSync(), 'pptx');
    check(r.contains('Folie 4 ersetzt') && txt.contains('Fado am Abend') && txt.contains('Belém') && pptx.length == 1, 'Folie 4 ersetzt, Rest bleibt, gleiche Datei');
    check(utf8.decode(readZip(pptx.single.readAsBytesSync())['ppt/slides/slide4.xml']!).contains('0B6E8E'), 'Design bleibt erhalten');
    await edit.run({'aktion': 'loeschen', 'datei': 'Lissabon', 'folie': 5, 'abschnitt': '', 'inhalt': ''}, ctx);
    check(!officeText(pptx.single.readAsBytesSync(), 'pptx').contains('Belém'), 'Folie löschen');
    await edit.run({'aktion': 'ersetzen', 'datei': '', 'folie': 1, 'abschnitt': '', 'inhalt': '# Lissabon 2027\nUnsere Familienreise'}, ctx);
    check(officeText(pptx.single.readAsBytesSync(), 'pptx').contains('Lissabon 2027'), 'Titelfolie ändern');
    var err = '';
    try {
      await edit.run({'aktion': 'ersetzen', 'datei': '', 'folie': 2, 'abschnitt': '', 'inhalt': 'x'}, ctx);
    } on ToolException catch (e) {
      err = e.message;
    }
    check(err.contains('Reiseroute'), 'Routenfolie: Hinweis statt Änderung');
    // Dokument
    await CreateDocumentTool(out).run({'title': 'Bericht', 'content': '# Bericht\n## Einleitung\nText A\n## Ergebnisse\nText B\n## Fazit\nText C', 'vorlage': ''}, ctx);
    final d = await edit.run({'aktion': 'ersetzen', 'datei': 'Bericht', 'folie': 0, 'abschnitt': 'Ergebnisse', 'inhalt': '## Ergebnisse\nNeue Zahlen'}, ctx);
    final src = FileSource.load(File('${dir.path}/Bericht.pdf'))!;
    check(d.contains('ersetzt') && src.content.contains('Neue Zahlen') && src.content.contains('Text C') && !src.content.contains('Text B'), 'Abschnitt im Dokument ersetzt');
  });

  await group('Agent: Datei statt Beschreibung', () async {
    final dir = Directory.systemTemp.createTempSync('deliver');
    final plan = '**Folie 1: Okzitanien (Titel)**\n* **Text:** „Dein Abenteuer im Süden.“\n* **Grafik-Idee:** Karte.\n'
        '**Folie 2: Highlights**\n* **Layout:** Raster\n* Wandern in den Pyrenäen\n* Kajak am Lac de Sainte-Croix\n\n---\n**Anleitung zur Umsetzung:**\n1. Öffne PowerPoint.';
    final planJson = jsonEncode({'thought': 'Plan', 'final_answer': plan});
    // 1) Modell beschreibt nur → nachhaken → dann ruft es das Tool
    final b1 = ScriptedBackend([
      planJson,
      jsonEncode({'thought': 'Jetzt', 'action': 'create_presentation', 'args': {'title': 'Okzitanien', 'content': '# A\n- x\n# B\n- y'}}),
      '{"thought": "ok", "final_answer": "Fertig."}',
    ]);
    final r1 = AgentRunner(engine: b1, systemPrompt: 'T', tools: [CreatePresentationTool(OutputSpace(dir))], requiredTool: 'create_presentation');
    final e1 = await r1.run(history: const [], userInput: 'Erstelle eine Powerpoint über Okzitanien', context: ToolContext()).toList();
    check(e1.whereType<ToolCalled>().any((e) => e.tool == 'create_presentation') && b1.prompts[1].contains('fertige PowerPoint'),
        'Nur beschrieben → Agent wird zum Erstellen angehalten');
    // 2) Modell bleibt stur → App erstellt die Präsentation selbst aus dem Plan
    final dir2 = Directory.systemTemp.createTempSync('deliver2');
    final b2 = ScriptedBackend([planJson, planJson, planJson]);
    final r2 = AgentRunner(engine: b2, systemPrompt: 'T', tools: [CreatePresentationTool(OutputSpace(dir2))], requiredTool: 'create_presentation');
    final e2 = await r2.run(history: const [], userInput: 'Erstelle eine Powerpoint über Okzitanien', context: ToolContext()).toList();
    final pptx = dir2.listSync().whereType<File>().where((f) => f.path.endsWith('.pptx')).toList();
    check(pptx.length == 1 && e2.whereType<FinalAnswer>().single.text.contains('PowerPoint'), 'Fallback: Präsentation aus dem Folienplan');
    final txt = officeText(pptx.single.readAsBytesSync(), 'pptx');
    check(txt.contains('Wandern in den Pyrenäen') && !txt.contains('Grafik-Idee') && !txt.contains('Öffne PowerPoint'),
        'Plan-Angaben (Layout, Anleitung) nicht auf den Folien');
    // 3) Design-Links nicht im Browser öffnen
    final b3 = ScriptedBackend([
      jsonEncode({'thought': 'ansehen', 'action': 'web_fetch', 'args': {'url': 'https://slidesgo.com/de/theme/peru-reise-tour'}}),
      jsonEncode({'thought': 'Jetzt', 'action': 'create_presentation', 'args': {'title': 'Peru', 'content': '# A\n- x'}}),
      '{"thought": "ok", "final_answer": "Fertig."}',
    ]);
    final r3 = AgentRunner(engine: b3, systemPrompt: 'T', tools: [WebFetchTool(), CreatePresentationTool(OutputSpace(Directory.systemTemp.createTempSync('d3')))],
        requiredTool: 'create_presentation');
    final e3 = await r3
        .run(history: const [], userInput: 'Erstelle eine Präsentation, Design wie https://slidesgo.com/de/theme/peru-reise-tour',
            context: ToolContext(requestNetwork: (_) async => false))
        .toList();
    check(!e3.whereType<ToolCalled>().any((e) => e.tool == 'web_fetch') && b3.prompts[1].contains('vorlage = https://slidesgo.com'),
        'Design-Links gehen an die Präsentation, nicht in den Browser');
    check(slidesFromPlan('## Einleitung\n- a\n## Schluss\n- b').content.startsWith('# Einleitung'), 'Plan mit Markdown-Überschriften');
  });

  await group('Beobachtung: Schwellenwerte, Duplikate, Wochenrückblick', () async {
    final a = parseAlertRequest('Melde dich, wenn die Nvidia-Aktie unter 120 fällt')!;
    check(a.op == 'below' && a.value == 120 && a.subject == 'Nvidia', 'Schwellenwert aus Satz: ${a.op} ${a.value} „${a.subject}“');
    final b = parseAlertRequest('Bitcoin über 100.000 Dollar')!;
    check(b.op == 'above' && b.value == 100000 && b.subject == 'Bitcoin', 'Tausenderpunkt und „über“');
    check(parseNumber('1.234,56') == 1234.56 && parseNumber('1,234.56') == 1234.56 && parseNumber('118,4') == 118.4 && parseNumber('120') == 120,
        'Zahlen deutsch/englisch');
    check(formatNumber(118.4) == '118,40' && formatNumber(100000) == '100.000' && formatNumber(120) == '120', 'Zahlen lesbar');
    // Kurs-Abfrage gescriptet
    var price = 125.0;
    final calls = <String>[];
    final checker = WatchChecker(fetcher: (u) async {
      calls.add(u.path);
      if (u.path.contains('/search')) return jsonEncode({'quotes': [{'symbol': 'NVDA', 'quoteType': 'EQUITY'}]});
      return jsonEncode({'chart': {'result': [{'meta': {'regularMarketPrice': price, 'currency': 'USD'}}]}});
    });
    final w = WatchItem(id: 'n', kind: WatchKind.topic, title: 'Nvidia', target: 'Nvidia Aktie', alertOp: 'below', alertValue: 120);
    var r = await checker.check(w);
    check(r.event == null && w.symbol == 'NVDA' && w.lastValue == 125, 'über der Schwelle: keine Meldung, Kürzel ermittelt');
    price = 118.4;
    r = await checker.check(w);
    check(r.event?.kind == 'alert' && r.event!.title.contains('unter 120') && r.event!.detail.contains('118,40 USD'), 'Schwelle unterschritten → Meldung');
    r = await checker.check(w);
    check(r.event == null, 'bleibt darunter: keine Wiederholung');
    price = 121;
    await checker.check(w);
    price = 119;
    r = await checker.check(w);
    check(r.event != null, 'erneut unterschritten → wieder Meldung');
    check(WatchItem.fromJson(jsonDecode(jsonEncode(w.toJson())) as Map<String, dynamic>).alertLabel == 'unter 120', 'Schwelle gespeichert');
    // Zahl auf einer Seite
    check(WatchChecker.numberOnPage('Produkt X\nPreis: € 1.299,00 inkl. MwSt', 'Preis') == 1299.0, 'Zahl neben Beschriftung');
    // Duplikate
    final merged = mergeDuplicates([
      {'title': 'Anleger setzen NVIDIA am Freitagabend unter Druck - finanzen.ch', 'link': 'https://a/1'},
      {'title': 'NVIDIA: Anleger setzen Aktie am Freitagabend unter Druck - finanzen.net', 'link': 'https://b/2'},
      {'title': 'George Soros verkauft Nvidia-Aktien - Handelsblatt', 'link': 'https://c/3'},
    ]);
    check(merged.length == 2 && merged.first['sources'] == 'finanzen.ch, finanzen.net', 'gleiche Meldung aus 2 Quellen zusammengefasst');
    var feed = '';
    final tc = WatchChecker(fetcher: (u) async {
      if (u.host == 'news.google.com') return feed;
      throw Exception('keine Websuche');
    });
    String rss(List<(String, String)> items) =>
        '<rss><channel>${items.map((i) => '<item><title>${i.$1}</title><link>${i.$2}</link></item>').join()}</channel></rss>';
    final topic = WatchItem(id: 't', kind: WatchKind.topic, title: 'nvidia', target: 'nvidia', recentOnly: true);
    feed = rss([('Alt - x.de', 'https://x/0')]);
    await tc.check(topic);
    feed = rss([('Alt - x.de', 'https://x/0'), ('Anleger setzen NVIDIA unter Druck - finanzen.ch', 'https://a/1'), ('NVIDIA: Anleger setzen Aktie unter Druck - finanzen.net', 'https://b/2')]);
    final e1 = (await tc.check(topic)).event;
    check(e1 != null && e1.links.length == 1 && e1.detail.contains('auch: finanzen.ch, finanzen.net'), 'Neue Treffer zusammengefasst');
    feed = rss([('Anleger setzen NVIDIA unter Druck - boerse.de', 'https://c/9')]);
    check((await tc.check(topic)).event == null, 'dieselbe Meldung später von anderer Quelle: nicht nochmal');
    // Wochenrückblick
    final d = WatchItem(id: 'd', kind: WatchKind.topic, title: 'x', target: 'x', digest: 'weeklyOnly');
    final sun = DateTime(2026, 11, 22, 19);
    check(!d.digestDue(sun.subtract(const Duration(days: 7))) && d.digestDue(sun) && !d.digestDue(sun.subtract(const Duration(days: 1))),
        'Rückblick sonntags, frühestens nach 6 Tagen');
    feed = rss([('Erste Meldung - a.de', 'https://q/1')]);
    await tc.check(d);
    feed = rss([('Erste Meldung - a.de', 'https://q/1'), ('Ganz andere Nachricht heute - b.de', 'https://q/2')]);
    final quiet = (await tc.check(d)).event;
    check(quiet?.kind == 'quiet' && quiet!.seen, 'Nur Rückblick: Einzeltreffer still gesammelt');
  });

  await group('Anbieter: 2442 API', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Map<String, dynamic>? got;
    String? key;
    var fail = false;
    server.listen((req) async {
      got = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      key = req.headers.value('x-api-key');
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(fail
          ? {'success': false, 'message': 'Rate-Limit erreicht'}
          : {'success': true, 'answer': got!['question'].toString().contains('ANTWORTFORMAT') ? '{"thought":"","final_answer":"Blau."}' : 'Weil Licht gestreut wird.', 'notification': 'groq hat keine freien Credits mehr.'}));
      await req.response.close();
    });
    final cfg = ProviderConfig(id: 'x', kind: ProviderKind.api2442, name: '2442', baseUrl: 'http://127.0.0.1:${server.port}', model: 'groq, gemini');
    final b = RemoteBackend(cfg, apiKey: 'ai2442_test');
    final p = await b.formatChat(const [ChatMessage('system', 'Sei kurz.'), ChatMessage('user', 'Warum ist der Himmel blau?')]);
    final text = StringBuffer();
    await for (final e in b.generate(p)) {
      if (e is TokenEvent) text.write(e.text);
    }
    check(key == 'ai2442_test' && (got!['favorites'] as List).join(',') == 'groq,gemini' && got!['question'].toString().contains('Sei kurz.'),
        '2442: Schlüssel, Favoriten und Verlauf gesendet');
    check(text.toString().startsWith('Weil Licht') && text.toString().contains('keine freien Credits'), '2442: Antwort + Hinweis');
    final js = StringBuffer();
    await for (final e in b.generate(p, grammar: 'root ::= final_answer')) {
      if (e is TokenEvent) js.write(e.text);
    }
    check(jsonDecode(js.toString())['final_answer'] == 'Blau.', '2442: Agenten-Format (JSON)');
    fail = true;
    String? err;
    await for (final e in b.generate(p)) {
      if (e is DoneEvent && e.reason == FinishReason.error) err = e.error;
    }
    check(err != null && err.contains('Rate-Limit'), '2442: Fehlermeldung statt Absturz');
    b.close();
    await server.close(force: true);
  });

  await group('Anbieter-API: OpenAI-kompatibel, Anthropic, Gemini', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <Map<String, dynamic>>[];
    final headers = <String, String>{};
    var script = <String>[];
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.method == 'GET') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(req.uri.path.contains('/gem/')
            ? jsonEncode({'models': [{'name': 'models/gemini-x', 'supportedGenerationMethods': ['generateContent']}, {'name': 'models/embed', 'supportedGenerationMethods': ['embedContent']}]})
            : jsonEncode({'data': [{'id': 'b-model'}, {'id': 'a-model'}]}));
        await req.response.close();
        return;
      }
      bodies.add(jsonDecode(body) as Map<String, dynamic>);
      headers['auth'] = req.headers.value('authorization') ?? req.headers.value('x-api-key') ?? req.headers.value('x-goog-api-key') ?? '';
      if (req.uri.path.contains('/bad/')) {
        req.response.statusCode = 401;
        req.response.write(jsonEncode({'error': {'message': 'Invalid API key'}}));
        await req.response.close();
        return;
      }
      final next = script.isEmpty ? 'OK' : script.removeAt(0);
      req.response.headers.contentType = ContentType('text', 'event-stream');
      final pieces = <String>[];
      for (var i = 0; i < next.length; i += 7) {
        pieces.add(next.substring(i, math.min(i + 7, next.length)));
      }
      if (req.uri.path.contains('/ant/')) {
        req.response.write('event: message_start\ndata: ${jsonEncode({'type': 'message_start', 'message': {'usage': {'input_tokens': 42}}})}\n\n');
        for (final p in pieces) {
          req.response.write('data: ${jsonEncode({'type': 'content_block_delta', 'delta': {'type': 'text_delta', 'text': p}})}\n\n');
        }
        req.response.write('data: ${jsonEncode({'type': 'message_delta', 'usage': {'output_tokens': 9}})}\n\n');
      } else if (req.uri.path.contains('/gem/')) {
        for (final p in pieces) {
          req.response.write('data: ${jsonEncode({'candidates': [{'content': {'parts': [{'text': p}]}}]})}\n\n');
        }
      } else {
        for (final p in pieces) {
          req.response.write('data: ${jsonEncode({'choices': [{'delta': {'content': p}}]})}\n\n');
        }
        req.response.write('data: [DONE]\n\n');
      }
      await req.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    Future<(String, DoneEvent)> gen(RemoteBackend b, List<ChatMessage> m, {String? grammar}) async {
      final buf = StringBuffer();
      DoneEvent? d;
      await for (final ev in b.generate(await b.formatChat(m), grammar: grammar)) {
        if (ev is TokenEvent) buf.write(ev.text);
        if (ev is DoneEvent) d = ev;
      }
      return (buf.toString(), d!);
    }

    final oa = RemoteBackend(ProviderConfig(id: 'o', kind: ProviderKind.compatible, name: 'Server', baseUrl: '$base/v1', model: 'qwen'), apiKey: 'k1');
    script = ['Hallo aus dem Server'];
    var (txt, done) = await gen(oa, const [ChatMessage('system', 'Sys'), ChatMessage('user', 'Hi')]);
    check(txt == 'Hallo aus dem Server' && done.reason == FinishReason.done, 'OpenAI-Stil: Text gestreamt');
    check(bodies.last['messages'][0]['role'] == 'system' && bodies.last['model'] == 'qwen' && headers['auth'] == 'Bearer k1',
        'OpenAI-Stil: System, Modell, Schlüssel');
    check(oa.contextSize == 32768 && oa.config.onPrem, 'On-Prem: Standard-Context 32K');

    // JSON-Modus: Codeblock und Text drumherum werden entfernt
    script = ['Gern!\n```json\n{"thought": "a {b}", "final_answer": "Text mit \\" und }"}\n```\nFertig.'];
    (txt, done) = await gen(oa, const [ChatMessage('user', 'x')], grammar: AgentGrammar.build(const []));
    final j = jsonDecode(txt) as Map;
    check(j['final_answer'] == 'Text mit " und }', 'JSON-Filter: nur das Objekt, Klammern in Strings ok');
    check((bodies.last['messages'][0]['content'] as String).contains('JSON-Objekt'), 'JSON-Hinweis im System-Prompt');

    // Kein JSON geliefert → als final_answer verpackt
    script = ['Einfach nur Text'];
    (txt, done) = await gen(oa, const [ChatMessage('user', 'x')], grammar: AgentGrammar.build(const []));
    check((jsonDecode(txt) as Map)['final_answer'] == 'Einfach nur Text', 'Ohne JSON: Text wird Endantwort');

    // Anthropic: Rollen zusammenführen, Nutzung
    final an = RemoteBackend(ProviderConfig(id: 'a', kind: ProviderKind.anthropic, name: 'Claude', baseUrl: '$base/ant/v1', model: 'claude-x'), apiKey: 'sk-ant');
    script = ['Antwort von Claude'];
    (txt, done) = await gen(an, const [
      ChatMessage('system', 'S'),
      ChatMessage('assistant', 'früher'),
      ChatMessage('user', 'a'),
      ChatMessage('user', 'b'),
    ]);
    final ab = bodies.last;
    final msgs = ab['messages'] as List;
    check(txt == 'Antwort von Claude' && ab['system'] == 'S', 'Anthropic: Text und System');
    check(msgs.first['role'] == 'user' && msgs.last['content'] == 'a\n\nb' && headers['auth'] == 'sk-ant',
        'Anthropic: beginnt mit user, gleiche Rollen zusammengeführt, x-api-key');
    check(done.stats.promptTokens == 42 && done.stats.generatedTokens == 9, 'Anthropic: Token-Zahlen aus der API');

    // Gemini
    final ge = RemoteBackend(ProviderConfig(id: 'g', kind: ProviderKind.gemini, name: 'Gemini', baseUrl: '$base/gem/v1beta', model: 'gemini-x'), apiKey: 'gk');
    script = ['Gemini sagt hallo'];
    (txt, done) = await gen(ge, const [ChatMessage('user', 'Hi'), ChatMessage('assistant', 'Hallo'), ChatMessage('user', 'Und?')]);
    final gb = bodies.last;
    check(txt == 'Gemini sagt hallo' && (gb['contents'] as List)[1]['role'] == 'model' && headers['auth'] == 'gk',
        'Gemini: Text, Rolle model, Schlüssel');
    check((await ge.listModels()).join(',') == 'gemini-x', 'Gemini: nur Modelle mit generateContent');
    check((await oa.listModels()).join(',') == 'a-model,b-model', 'Modellliste sortiert');

    // Fehler
    final bad = RemoteBackend(ProviderConfig(id: 'b', kind: ProviderKind.openai, name: 'OpenAI', baseUrl: '$base/bad/v1', model: 'm'), apiKey: 'x');
    (txt, done) = await gen(bad, const [ChatMessage('user', 'x')]);
    check(done.reason == FinishReason.error && done.error!.contains('401') && done.error!.contains('Invalid API key'),
        'HTTP-Fehler mit Meldung (${done.error})');
    final gone = RemoteBackend(ProviderConfig(id: 'z', kind: ProviderKind.ollama, name: 'Ollama', baseUrl: 'http://127.0.0.1:1/v1', model: 'm'));
    (txt, done) = await gen(gone, const [ChatMessage('user', 'x')]);
    check(done.reason == FinishReason.error && done.error!.contains('nicht erreichbar'), 'Server aus: verständliche Meldung');

    // Agenten-Schleife über die API: Werkzeug, dann Antwort
    script = [
      '```json\n{"thought": "rechnen", "action": "calculator", "args": {"expression": "6*7"}}\n```',
      '{"thought": "fertig", "final_answer": "Das sind 42."}',
    ];
    final runner = AgentRunner(engine: oa, systemPrompt: 'Test', tools: builtinTools(), maxSteps: 4);
    final events = await runner.run(history: const [], userInput: '6*7?', context: ToolContext()).toList();
    check(events.whereType<ToolResult>().first.output == '6*7 = 42', 'Agent über API ruft Werkzeug auf');
    check(events.whereType<FinalAnswer>().single.text == 'Das sind 42.', 'Agent über API antwortet');
    final ser = ProviderConfig.fromJson(oa.config.toJson());
    check(ser.kind == ProviderKind.compatible && ser.baseUrl == '$base/v1' && ser.onPrem, 'Konfiguration speichern/laden');
    await server.close(force: true);
  });

  await group('Watchlist: Seiten und Themen', () async {
    var page = '<html><body><h1>Jobs</h1><p>Stand 10:15 Uhr</p><ul>'
        '<li><a href="/job/1"><h3>Entwickler Flutter</h3></a></li>'
        '<li><a href="/job/2"><h3>Designerin UI</h3></a></li></ul></body></html>';
    var rss = '<rss><channel><item><title>Anthropic stellt neues Modell vor</title><link>https://news.example/a</link></item></channel></rss>';
    final checker = WatchChecker(fetcher: (u) async {
      if (u.host == 'news.google.com') return rss;
      if (u.host.contains('duckduckgo') || u.host.contains('bing') || u.host.contains('mojeek')) return '<html></html>';
      return page;
    });
    final item = WatchItem(id: 'w1', kind: WatchKind.page, title: 'Jobs', target: 'example.com/jobs');
    var r = await checker.check(item, now: DateTime(2026, 11, 21, 10));
    check(r.first && r.event == null && item.fingerprint != null, 'Seite: erster Stand ohne Meldung');
    page = page.replaceFirst('10:15', '11:40');
    r = await checker.check(item, now: DateTime(2026, 11, 21, 11));
    check(r.event == null && r.error == null, 'Seite: nur Uhrzeit geändert → nichts Neues');
    page = page.replaceFirst('</ul>', '<li><a href="/job/3"><h3>Data Scientist Wien</h3></a></li></ul>');
    r = await checker.check(item, now: DateTime(2026, 11, 21, 12));
    check(r.event != null && r.event!.detail.contains('Data Scientist Wien'), 'Seite: neuer Eintrag erkannt (${r.event?.title})');
    check(item.events.length == 1 && item.unseen == 1, 'Ereignis gespeichert, ungelesen');
    check(!item.due(DateTime(2026, 11, 21, 13)) && item.due(DateTime(2026, 11, 21, 18, 1)), 'Fälligkeit nach Intervall (6 h)');
    final back = WatchItem.fromJson(jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>);
    check(back.events.single.title == item.events.single.title && back.fingerprint == item.fingerprint, 'Speichern/Laden');

    final topic = WatchItem(id: 't1', kind: WatchKind.topic, title: 'Anthropic', target: 'Anthropic');
    r = await checker.check(topic);
    check(r.first && topic.seenLinks.isNotEmpty, 'Thema: erste Treffer gemerkt');
    r = await checker.check(topic);
    check(r.event == null, 'Thema: keine neuen Treffer');
    rss = rss.replaceFirst('</channel>', '<item><title>Claude kann jetzt mehr</title><link>https://news.example/b</link></item></channel>');
    r = await checker.check(topic);
    check(r.event != null && r.event!.links.single['link'] == 'https://news.example/b', 'Thema: neuer Treffer gemeldet');
    final broken = WatchChecker(fetcher: (u) async => throw Exception('offline'));
    r = await broken.check(WatchItem(id: 'x', kind: WatchKind.page, title: 'x', target: 'https://x.y'));
    check(r.error != null, 'Fehler wird gemeldet statt zu werfen');
  });

  await group('Prozesse: Modell, Reihenfolge, Erzeugen', () async {
    final wf = Workflow(id: 'f1', name: 'Test');
    wf.nodes.addAll([
      FlowNode(id: 'a', type: FlowNodeType.trigger, title: 'Start', config: {'mode': 'schedule', 'hour': 7, 'minute': 30, 'days': 'weekdays'}),
      FlowNode(id: 'b', type: FlowNodeType.agent, title: 'News', config: {'prompt': 'Suche News'}),
      FlowNode(id: 'c', type: FlowNodeType.condition, title: 'Wichtig?', config: {'contains': 'KI'}),
      FlowNode(id: 'd', type: FlowNodeType.notify, title: 'Push'),
    ]);
    wf.connect('a', 'b');
    wf.connect('b', 'c');
    wf.connect('c', 'd');
    wf.connect('d', 'a'); // Kreis wird verhindert
    check(wf.edges.length == 3, 'Kreise werden nicht verbunden');
    check(wf.order().map((n) => n.id).join() == 'abcd', 'Reihenfolge ab Auslöser');
    check(wf.problems(const {}).isEmpty, 'keine Lücken');
    check(wf.dueAt(DateTime(2026, 11, 23, 7, 31)) && !wf.dueAt(DateTime(2026, 11, 22, 7, 31)) && !wf.dueAt(DateTime(2026, 11, 23, 7, 0)),
        'Zeitplan Mo–Fr 7:30 fällig');
    wf.lastRun = DateTime(2026, 11, 23, 7, 31);
    check(!wf.dueAt(DateTime(2026, 11, 23, 8)) && wf.dueAt(DateTime(2026, 11, 24, 7, 35)), 'nur einmal pro Tag');
    check(Workflow.fill('A {{vorher}} B {{ datum }} {{x}}', {'vorher': '1', 'datum': '2'}) == 'A 1 B 2 ', 'Platzhalter');
    final back = Workflow.fromJson(jsonDecode(jsonEncode(wf.toJson())) as Map<String, dynamic>);
    check(back.nodes.length == 4 && back.edges.length == 3 && back.trigger!.summary == 'Mo–Fr 07:30', 'Speichern/Laden, Kurztext');

    const modelOut = 'Hier ist der Prozess:\n```json\n'
        '{"name": "Tech-News", "nodes": ['
        '{"id": "s", "type": "schedule", "title": "Jeden Morgen", "hour": "7"},'
        '{"id": "x", "type": "tool", "title": "News", "config": {"tool": "news", "args": {"section": "tech"}}},'
        '{"id": "y", "type": "llm", "title": "Zusammenfassen", "prompt": "Fasse {{vorher}} zusammen"},'
        '{"id": "z", "type": "push", "title": "Senden", "config": {"text": "{{vorher}}"}}]}\n```';
    final gen = Workflow.fromModelJson(modelOut, id: 'g', toolNames: {'news', 'weather'});
    check(gen != null && gen.nodes.length == 4, 'Modell-JSON gelesen (Codeblock, Varianten)');
    check(gen!.trigger!.config['mode'] == 'schedule' && gen.trigger!.config['hour'] == 7, 'Auslöser mit Uhrzeit');
    check(gen.nodes[2].type == FlowNodeType.agent && gen.nodes[2].str('prompt').contains('{{vorher}}'), 'llm → agent mit prompt');
    check(gen.edges.length == 3 && gen.order().last.type == FlowNodeType.notify, 'ohne Kanten der Reihe nach verbunden');
    check(gen.nodes.map((n) => n.x).toSet().length == 4, 'automatisch angeordnet');
    final unknown = Workflow.fromModelJson('{"nodes": [{"type": "tool", "config": {"tool": "fax"}}]}', id: 'u', toolNames: {'news'});
    check(unknown!.trigger != null && unknown.nodes.last.type == FlowNodeType.agent, 'unbekanntes Werkzeug → Agent, Auslöser ergänzt');
    check(Workflow.fromModelJson('kein json', id: 'q') == null, 'ungültig → null');
    check(FlowNodeType.parse('crew') == FlowNodeType.team && FlowNodeType.parse('n8n') == FlowNodeType.platform, 'Team/Plattform erkannt');
    check(FlowNode(id: 't', type: FlowNodeType.team, title: 'T', config: {'members': [{'name': 'Recherche'}, {'name': 'Prüfer'}], 'review': true}).summary == 'Recherche → Prüfer ↺', 'Team-Zusammenfassung');
    check(FlowNodeType.parse('skill') == FlowNodeType.skill && FlowNodeType.parse('Fähigkeit') == FlowNodeType.skill, 'Skill-Baustein erkannt');
    check(FlowNode(id: 's', type: FlowNodeType.skill, title: 'S', config: {'skillName': 'Bericht', 'skillCommand': 'bericht', 'prompt': 'Nov'}).summary.contains('/bericht'), 'Skill-Zusammenfassung');

    final h = Workflow.fromDescription('Jeden Morgen um 6:45 die Wetterlage für Wien prüfen und mir schicken', id: 'h');
    check(h.trigger!.config['hour'] == 6 && h.trigger!.config['minute'] == 45 && h.nodes.length == 3, 'Ohne Modell: Zeitplan erkannt (${h.trigger!.config})');
    check(Workflow.scheduleOf('werktags um 8 Uhr')!.$3 == 'weekdays' && Workflow.scheduleOf('jeden Abend')!.$1 == 19 &&
        Workflow.scheduleOf('Fasse den Artikel zusammen') == null, 'Zeitangaben');
  });

  await group('Agent: Schrittlimit erzwingt Endantwort', () async {
    final backend = ScriptedBackend([
      for (var i = 0; i < 3; i++) '{"thought": "t", "action": "datetime", "args": {}}',
      '{"thought": "muss", "final_answer": "Abschluss"}',
    ]);
    final runner = AgentRunner(engine: backend, systemPrompt: 'T', tools: [DateTimeTool()], maxSteps: 2);
    final events = await runner.run(history: const [], userInput: 'x', context: ToolContext()).toList();
    check(backend.grammars.last != null && !backend.grammars.last!.contains('call ::='), 'letzter Schritt nur final_answer erlaubt');
    check(backend.prompts.last.contains('Schrittlimit erreicht'), 'Hinweis im Prompt');
    check(events.whereType<AgentFinished>().single.reason == AgentStopReason.stepLimit, 'Grund stepLimit');
  });

  await group('Agent: Kürzen alter Schritte', () async {
    final big = 'x' * 1800;
    final backend = ScriptedBackend([
      for (var i = 0; i < 5; i++) '{"thought": "lesen $i", "action": "read_file", "args": {"name": "gross.txt", "start": ${i * 3000}}}',
      '{"thought": "ok", "final_answer": "fertig"}',
    ], contextSize: 2200);
    final runner = AgentRunner(
        engine: backend, systemPrompt: 'T', tools: [ReadFileTool()], maxSteps: 8, maxTokensPerStep: 200);
    final events = await runner
        .run(history: const [], userInput: 'lies', context: ToolContext(attachments: [Attachment(name: 'gross.txt', content: big * 10)]))
        .toList();
    final fin = events.whereType<AgentFinished>().single;
    check(fin.reason == AgentStopReason.answered, 'läuft trotz kleinem Context durch (${fin.message ?? ''})');
    check(backend.prompts.any((p) => p.contains('[Frühere Schritte wurden')), 'alte Schritte zusammengefasst');
  });

  await group('Audio: WAV und Resampling', () async {
    final tone = Float32List.fromList([for (var i = 0; i < 48000; i++) 0.5 * math.sin(i / 10)]);
    final wav = encodeWav16(tone, 48000);
    check(wav.length == 44 + 96000, 'WAV-Größe korrekt');
    final back = decodeWavTo16kMono(wav);
    check(back.length == 16000, '48 kHz → 16 kHz (1 s = ${back.length} Samples)');
    check(back.reduce(math.max) > 0.45 && back.reduce(math.max) < 0.51, 'Amplitude erhalten');
    var threw = false;
    try {
      decodeWavTo16kMono(Uint8List.fromList(List.filled(100, 1)));
    } on FormatException {
      threw = true;
    }
    check(threw, 'Nicht-WAV wird abgelehnt');
    final free = SttEngine.freeDiskBytes(Directory.systemTemp.path);
    check(free > 0, 'freier Speicher lesbar (${free ~/ (1 << 30)} GB)');
  });

  final whisperModel = Platform.environment['AE_TEST_WHISPER'] ?? '';
  final jfk = Platform.environment['AE_TEST_WAV'] ?? '';
  if (whisperModel.isNotEmpty && jfk.isNotEmpty) {
    await group('Whisper: Laden und Transkribieren', () async {
      final stt = await SttEngine.load(whisperModel);
      final pcm = decodeWavTo16kMono(File(jfk).readAsBytesSync());
      check(pcm.length > 16000 * 10, 'Testaufnahme ≥ 10 s (${pcm.length ~/ 16000} s)');
      final t = await stt.transcribe(pcm, language: 'en', threads: 4);
      print('  Text: "${t.text}" (${t.language}, ${t.duration.inMilliseconds} ms)');
      check(t.language == 'en', 'Sprache en');
      await stt.dispose();
      var threw = false;
      try {
        await SttEngine.load('/gibt/es/nicht.bin');
      } on EngineException {
        threw = true;
      }
      check(threw, 'fehlendes Whisper-Modell → EngineException');
    });
  }

  await group('Katalog: Empfehlungen je Gerät', () async {
    const gb = 1 << 30;
    final s = DeviceProfile.detect(totalMemoryOverride: 4 * gb, cpuOverride: 8);
    final m = DeviceProfile.detect(totalMemoryOverride: 8 * gb, cpuOverride: 8);
    final l = DeviceProfile.detect(totalMemoryOverride: 16 * gb, cpuOverride: 10);
    String best(ModelKind k, DeviceProfile d, [int free = 100 * gb]) =>
        recommendFor(k, d, freeDiskBytes: free, availableMemory: 0).first.entry.id;
    final xl = DeviceProfile.detect(totalMemoryOverride: 128 * gb, cpuOverride: 16);
    check(best(ModelKind.llm, s) == 'qwen3.5-2b', 'S → Qwen 3.5 2B');
    check(best(ModelKind.llm, m) == 'qwen3.5-4b', 'M → Qwen 3.5 4B');
    check(best(ModelKind.llm, l) == 'qwen3.5-9b', 'L → Qwen 3.5 9B');
    check(xl.deviceClass == DeviceClass.xl && xl.maxContext == 16384, 'XL bei 128 GB, 16K Context');
    check(best(ModelKind.llm, xl) == 'gemma-4-26b-a4b', 'XL → Gemma 4 26B A4B');
    check(best(ModelKind.stt, xl) == 'parakeet-v3', 'XL → Parakeet');
    check(best(ModelKind.stt, s) == 'canary-de', 'S → Canary');
    check(best(ModelKind.stt, m) == 'parakeet-v3', 'M Desktop → Parakeet');
    final phone12 = DeviceProfile.detect(totalMemoryOverride: 12 * gb, cpuOverride: 8, mobileOverride: true);
    check(best(ModelKind.stt, phone12) == 'canary-de', 'Handy → Canary (schnell für Gespräche)');
    // Rechner (Linux/macOS) gilt als Desktop → volle Präzision
    check(best(ModelKind.stt, l) == 'parakeet-v3', 'L Desktop → Parakeet');
    check(best(ModelKind.tts, m) == 'piper-de-thorsten', 'Stimme → Thorsten');
    final noSpace = recommendFor(ModelKind.llm, l, freeDiskBytes: 1 * gb);
    check(noSpace.firstWhere((r) => r.entry.id == 'qwen3.5-9b').suitability == Suitability.noSpace,
        'zu wenig Speicher erkannt');
    final tooBig = recommendFor(ModelKind.llm, s, freeDiskBytes: 100 * gb);
    check(tooBig.firstWhere((r) => r.entry.id == 'qwen3.5-9b').suitability == Suitability.tooBig,
        '9B auf S als zu groß markiert');
    // Handy mit 10.9 GB, aber nur 3.6 GB frei: Budget 40 % → 9B und 12B ausgegraut
    final phone = DeviceProfile.detect(totalMemoryOverride: (10.9 * gb).round(), cpuOverride: 8, mobileOverride: true);
    final pr = recommendFor(ModelKind.llm, phone, freeDiskBytes: 100 * gb, availableMemory: (3.6 * gb).round());
    Suitability su(String id) => pr.firstWhere((r) => r.entry.id == id).suitability;
    check(su('qwen3.5-9b') == Suitability.tooBig && su('gemma-4-12b') == Suitability.tooBig,
        'Handy: zu große Modelle nach Arbeitsspeicher ausgegraut');
    check(pr.first.suitability == Suitability.recommended &&
            DeviceProfile.estimateRuntimeBytes(pr.first.entry.sizeBytes) <= phone.memoryBudget((3.6 * gb).round()),
        'Handy: Empfehlung passt in den Speicher (${pr.first.entry.id})');
    check(pr.first.entry.id == 'qwen3.5-4b', 'Handy: Empfehlung fällt auf die M-Empfehlung zurück');
    check(modelCatalog.map((e) => e.id).toSet().length == modelCatalog.length, 'IDs eindeutig');
    check(modelCatalog.every((e) => e.url.startsWith('https://') && e.url.endsWith(e.fileName)),
        'URLs enden auf Dateiname');
  });

  await group('Download: Weiterleitung, Fortsetzen, Abbruch', () async {
    final payload = List<int>.generate(3 * 1024 * 1024 + 123, (i) => (i * 31) & 0xff);
    var failOnce = true;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.uri.path == '/redirect') {
        req.response
          ..statusCode = 302
          ..headers.set('location', '/file.bin');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/missing') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final range = req.headers.value('range');
      var start = 0;
      if (range != null) start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      final res = req.response;
      if (start > 0) {
        res.statusCode = 206;
        res.headers.set('content-range', 'bytes $start-${payload.length - 1}/${payload.length}');
      }
      res.contentLength = payload.length - start;
      if (failOnce && start == 0) {
        // erste Verbindung nach 1 MB abbrechen
        failOnce = false;
        final sock = await res.detachSocket(writeHeaders: true);
        sock.add(payload.sublist(0, 1024 * 1024));
        await sock.flush();
        sock.destroy();
        return;
      }
      res.add(payload.sublist(start));
      await res.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final dir = Directory.systemTemp.createTempSync('dl');
    final target = '${dir.path}/model.bin';
    final dl = Downloader();
    var threw = false;
    try {
      await dl.download('$base/redirect', target);
    } on DownloadException catch (e) {
      threw = true;
      print('  erster Versuch: $e');
    }
    check(threw, 'abgebrochene Verbindung meldet Fehler');
    check(File('$target.part').existsSync() && File('$target.part').lengthSync() >= 1024 * 1024,
        '.part-Datei mit ${File('$target.part').lengthSync() ~/ 1024} KB bleibt');
    final progress = <DownloadProgress>[];
    final f = await dl.download('$base/redirect', target, onProgress: progress.add);
    final got = f.readAsBytesSync();
    check(got.length == payload.length, 'Fortsetzen ergibt volle Länge');
    var same = true;
    for (var i = 0; i < got.length; i += 4099) {
      if (got[i] != payload[i]) same = false;
    }
    check(same, 'Inhalt identisch');
    check(progress.isNotEmpty && progress.last.received == payload.length && progress.last.total == payload.length,
        'Fortschritt erreicht 100 %');
    check(!File('$target.part').existsSync(), '.part entfernt');
    threw = false;
    try {
      await dl.download('$base/missing', '${dir.path}/x.bin');
    } on DownloadException catch (e) {
      threw = e.message.contains('404');
    }
    check(threw, '404 mit verständlicher Meldung');
    final token = CancelToken()..cancel();
    threw = false;
    try {
      await dl.download('$base/file.bin', '${dir.path}/y.bin', cancel: token);
    } on DownloadCancelled {
      threw = true;
    }
    check(threw, 'Abbrechen wirkt');
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  await group('Web-Tools: Parser und Freigabe', () async {
    const ddg = '<div class="result__body"><h2><a rel="nofollow" class="result__a" '
        'href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.wien.gv.at%2Fwetter&amp;rut=x">Wetter &amp; Klima Wien</a></h2>'
        '<a class="result__snippet" href="x">Aktuelle <b>Werte</b> f&uuml;r Wien</a></div>'
        '<div class="result__body"><a class="result__a" href="https://duckduckgo.com/y.js?ad=1">Anzeige</a></div>';
    final hits = WebSearchTool.parseDuckDuckGo(ddg);
    check(hits.length == 1, 'DuckDuckGo: 1 Treffer, Anzeige ignoriert');
    check(hits.first.url == 'https://www.wien.gv.at/wetter', 'Ziel-URL dekodiert');
    check(hits.first.title == 'Wetter & Klima Wien' && hits.first.snippet == 'Aktuelle Werte für Wien', 'Titel/Text bereinigt');
    final text = htmlToText('<html><head><title>T</title><style>x{}</style></head><body><h1>Hallo</h1>'
        '<script>alert(1)</script><p>Erste&nbsp;Zeile</p><ul><li>A</li><li>B</li></ul></body></html>');
    check(text == 'Hallo\nErste Zeile\n\n• A\n• B' || text.contains('Erste Zeile') && !text.contains('alert'),
        'HTML → Text ohne Skripte');
    final asked = <String>[];
    final search = WebSearchTool(fetcher: (u) async => ddg);
    final ok = await search.run({'query': 'Wetter Wien'},
        ToolContext(requestNetwork: (p) async {
          asked.add(p);
          return true;
        }));
    check(asked.single.contains('Wetter Wien') && ok.contains('wien.gv.at'), 'Freigabe gefragt, Ergebnis geliefert');
    var denied = false;
    try {
      await search.run({'query': 'x'}, ToolContext(requestNetwork: (_) async => false));
    } on ToolException catch (e) {
      denied = e.message.contains('abgelehnt');
    }
    check(denied, 'Ablehnung wird an den Agenten gemeldet');
    var blocked = false;
    try {
      await WebFetchTool(fetcher: (u) async => '').run({'url': 'http://192.168.1.1/admin'},
          ToolContext(requestNetwork: (_) async => true));
    } on ToolException {
      blocked = true;
    }
    check(blocked, 'lokale Adressen gesperrt');
    final g = AgentGrammar.build([...builtinTools(), ...networkTools()]);
    check(g.contains('tool-web-search') && g.contains('tool-web-fetch'), 'Web-Tools in der Grammatik');
  });

  await group('Wissensbasis: Chunking, BM25, Crawling', () async {
    final long = List.generate(60, (i) => 'Satz $i über Thema ${i % 5}. ').join() * 3;
    final ch = chunkText(long);
    check(ch.length > 3 && ch.every((c) => c.length <= 950), 'Text in ${ch.length} Abschnitte ≤ 950 Zeichen');
    final dir = Directory.systemTemp.createTempSync('kb');
    final kb = KnowledgeBase(dir);
    kb.putSource(KnowledgeSource(id: 'a', name: 'Bad', origin: 'https://x.at', kind: 'web'), [
      (title: 'Öffnungszeiten', url: 'https://x.at/zeiten', text: 'Das Hallenbad hat Montag bis Freitag von 9 bis 21 Uhr geöffnet. Am Wochenende von 10 bis 18 Uhr.'),
      (title: 'Preise', url: 'https://x.at/preise', text: 'Eine Tageskarte kostet 7,50 Euro. Kinder zahlen 3 Euro. Die Saisonkarte kostet 120 Euro.'),
    ]);
    kb.putSource(KnowledgeSource(id: 'b', name: 'Rezepte', origin: 'rezepte.txt', kind: 'file'), [
      (title: 'Kuchen', url: 'rezepte.txt', text: 'Für den Apfelkuchen braucht man Äpfel, Mehl, Butter und Zucker. Backzeit 45 Minuten.'),
    ]);
    var hits = kb.search('Wann hat das Hallenbad geöffnet?');
    check(hits.isNotEmpty && hits.first.chunk.url == 'https://x.at/zeiten', 'Öffnungszeiten gefunden');
    hits = kb.search('Was kostet die Tageskarte');
    check(hits.isNotEmpty && hits.first.chunk.title == 'Preise', 'Preise gefunden');
    hits = kb.search('Äpfel backen');
    check(hits.isNotEmpty && hits.first.chunk.sourceId == 'b', 'Umlaute/Flexion: Äpfel → Apfelkuchen-Abschnitt');
    check(kb.search('Raumfahrt Mars').isEmpty, 'kein Treffer bei fremdem Thema');
    kb.putSource(KnowledgeSource(id: 'c', name: 'Amt', origin: 'https://amt.example', kind: 'web'), [
      (title: 'Bildnachweise', url: 'https://amt.example/bild', text: 'Heute mache ich die Bildnachweise. Wie man Fotos lizenziert.'),
      (title: 'Führerschein', url: 'https://amt.example/fs', text: 'Welcher Tag ist heute? Der Führerschein wird am Donnerstag ausgestellt.'),
    ]);
    check(kb.search('Wie mache ich Spaghetti?').isEmpty, 'keine Zufallstreffer über Allerweltswörter (Spaghetti)');
    check(kb.search('Welcher Wochentag ist heute?').isEmpty, 'keine Zufallstreffer (Wochentag)');
    check(kb.search('Führerschein ausstellen').isNotEmpty, 'echte Treffer bleiben');
    kb.removeSource('c');
    final ctx = kb.contextFor('Preise Kinder');
    check(ctx.contains('[1] Preise – https://x.at/preise'), 'Kontextblock mit Quelle');
    await kb.save();
    final kb2 = KnowledgeBase(dir);
    await kb2.load();
    check(kb2.sources.length == 2 && kb2.search('Saisonkarte').isNotEmpty, 'gespeichert und neu geladen');
    kb2.removeSource('a');
    check(kb2.search('Saisonkarte').isEmpty, 'Quelle entfernt');

    // Crawling mit lokalem Server
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final p = req.uri.path;
      req.response.headers.contentType = ContentType.html;
      final pages = {
        '/docs/': '<html><head><title>Start</title></head><body><nav><a href="/docs/a">A</a></nav><main><h1>Willkommen</h1><p>${'Startseite Inhalt. ' * 10}</p><a href="/docs/a">A</a> <a href="b">B</a> <a href="/anderes/c">C</a> <a href="https://fremd.at/x">X</a> <a href="/docs/bild.png">P</a></main></body></html>',
        '/docs/a': '<html><title>Seite A</title><body><p>${'Inhalt A über Datenschutz. ' * 10}</p></body></html>',
        '/docs/b': '<html><title>Seite B</title><body><p>${'Inhalt B über Barrierefreiheit. ' * 10}</p></body></html>',
      };
      if (pages.containsKey(p)) {
        req.response.write(pages[p]);
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}/docs/');
    final one = await crawlSite(base);
    check(one.length == 1 && one.first.title == 'Start' && !one.first.text.contains('<'), 'Einzelseite geladen, Titel/Text');
    final all = await crawlSite(base, followLinks: true);
    final urls = all.map((p) => Uri.parse(p.url).path).toSet();
    check(urls.containsAll({'/docs/', '/docs/a', '/docs/b'}) && urls.length == 3,
        'Unterseiten gecrawlt, fremde Pfade/Domains/Bilder ausgelassen ($urls)');
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  await group('Gedächtnis-Tools', () async {
    final saved = <String>[];
    final r = await RememberTool((f, k) async {
      saved.add(f);
      return null;
    }).run({'fact': 'Nutzer heißt Christoph', 'category': 'person'}, ToolContext());
    check(saved.single == 'Nutzer heißt Christoph' && r.startsWith('Gemerkt'), 'remember speichert');
    final convs = [
      (title: 'Urlaub', date: DateTime(2026, 11, 1), messages: [
        (role: 'user', text: 'Ich plane einen Urlaub in Kroatien im Juni.'),
        (role: 'assistant', text: 'Schön! Split und Dubrovnik sind im Juni toll.'),
      ]),
      (title: 'Code', date: DateTime(2026, 11, 2), messages: [
        (role: 'user', text: 'Wie schreibe ich eine PHP-Funktion?'),
        (role: 'assistant', text: 'So: function foo() {}'),
      ]),
    ];
    final h = searchConversations('Kroatien Urlaub', convs);
    check(h.isNotEmpty && h.first.contains('„Urlaub“') && h.first.contains('Dubrovnik'), 'früheres Gespräch gefunden');
    final tool = HistorySearchTool((q) => searchConversations(q, convs));
    check((await tool.run({'query': 'Rakete'}, ToolContext())).startsWith('Nichts'), 'kein Treffer sauber gemeldet');
  });

  await group('Gesprochene Ausgabe: Satz-Streaming', () async {
    final s = SentenceStreamer();
    check(s.feed('Hallo, ich').isEmpty, 'unvollständiger Satz wartet');
    final a = s.feed('Hallo, ich bin dein Agent. Heute ist es son');
    check(a.length == 1 && a.first == 'Hallo, ich bin dein Agent.', 'erster Satz sofort ($a)');
    final b = s.feed('Hallo, ich bin dein Agent. Heute ist es sonnig in **Wien**! Mehr');
    check(b.length == 1 && b.first == 'Heute ist es sonnig in Wien!', 'Markdown entfernt ($b)');
    final c = s.feed('Hallo, ich bin dein Agent. Heute ist es sonnig in **Wien**! Mehr gibt es nicht', done: true);
    check(c.single == 'Mehr gibt es nicht', 'Rest am Ende');
    check(s.spokenSoFar.endsWith('Mehr gibt es nicht'), 'gesprochener Text nachvollziehbar');
  });

  await group('Gesprochene Ausgabe: Abkürzungen und Aussprache', () async {
    final parts = splitForSpeech('Das gilt z. B. am 3. Mai in Wien. Dr. Huber kommt um 14:30 Uhr. Fertig!');
    check(parts.length == 2 && parts.first.contains('z. B. am 3. Mai'), 'kein Satzende nach z. B. und 3. ($parts)');
    final st = SentenceStreamer();
    check(st.feed('Es sind z. ').isEmpty, 'Streaming wartet nach „z.“');
    final n = normalizeForSpeech('Um 14:30 sind es z. B. 21 °C, ca. 5 % mehr – 3–5 km/h (leicht) & sonnig 🌞');
    check(n.contains('14 Uhr 30') && n.contains('zum Beispiel') && n.contains('21 Grad') && n.contains('circa') &&
        n.contains('5 Prozent') && n.contains('3 bis 5 Kilometer pro Stunde') && n.contains(' und ') && !n.contains('🌞'), 'normalisiert ($n)');
  });

  await group('Watchlist: Suchanfrage, Intervalle', () async {
    final q = SearchQuery.parse('"Wiener Linien" Störung -Wartung site:orf.at');
    check(q.phrases.single == 'wiener linien' && q.excludes.single == 'wartung' && q.sites.single == 'orf.at', 'Operatoren erkannt');
    check(q.accepts('U4 Störung', '', 'https://wien.orf.at/x'), 'passender Treffer bleibt');
    check(!q.accepts('Wartung U6', '', 'https://wien.orf.at/x'), '-Wort schließt aus');
    check(!q.accepts('Störung', '', 'https://example.com/x'), 'site: filtert');
    final w = WatchItem(id: 'm', kind: WatchKind.topic, title: 't', target: 'x', intervalMinutes: 1, lastCheck: DateTime(2026, 1, 1, 10, 0, 0));
    check(!w.due(DateTime(2026, 1, 1, 10, 0, 30)) && w.due(DateTime(2026, 1, 1, 10, 0, 50)), 'minütlich fällig');
    check(WatchItem.labelFor(5) == 'alle 5 Minuten' && WatchItem.labelFor(1440) == 'täglich', 'Beschriftung');
    final r = WatchItem.fromJson(WatchItem(id: 'a', kind: WatchKind.topic, title: 't', target: 'Wunsch', promptMode: true, query: 'q', recentOnly: true, flowId: 'f').toJson());
    check(r.promptMode && r.query == 'q' && r.recentOnly && r.flowId == 'f' && r.searchQuery == 'q', 'neue Felder gespeichert');
  });

  await group('Prozesse: Auto-Verbinden und neue Bausteine', () async {
    final wf = Workflow(id: 'w', name: 'T', nodes: [
      FlowNode(id: 'a', type: FlowNodeType.trigger, title: 'Start', x: 0, y: 100),
      FlowNode(id: 'b', type: FlowNodeType.http, title: 'API', config: {'url': 'https://api.example.com/x'}, x: 320, y: 100),
      FlowNode(id: 'c', type: FlowNodeType.notify, title: 'Push', x: 640, y: 110),
    ]);
    check(wf.autoConnect() == 2 && wf.order().map((n) => n.id).join() == 'abc', 'lose Bausteine logisch verbunden');
    check(wf.attachPoint()?.id == 'c', 'Anhängepunkt = Ende der Kette');
    check(wf.problems({}).isEmpty, 'keine Probleme (${wf.problems({})})');
    wf.node('b')!.config['url'] = 'ftp:/x';
    check(wf.problems({}).any((p) => p.contains('https')), 'ungültige Adresse erkannt');
    check(FlowNodeType.parse('rest') == FlowNodeType.http, 'Alias rest → Web-API');
    check(jsonPath({'items': [{'title': 'A'}]}, 'items.0.title') == 'A', 'JSON-Pfad');
    check(httpStatusHint(401).contains('Anmeldung'), 'Hinweis zu 401');
  });

  await group('Präsentation: Bilder automatisch erzeugen', () async {
    final dir = Directory.systemTemp.createTempSync('ae_img');
    final prompts = <String>[];
    // 1×1-PNG als „erzeugtes Bild“
    final png = base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');
    var n = 0;
    final out = OutputSpace(dir, imageGenerator: () => (p, f, neg) async {
          prompts.add(p);
          final file = File('${dir.path}/gen${n++}.png')..writeAsBytesSync(png);
          return file.path;
        });
    final arts = <Artifact>[];
    final r = await CreatePresentationTool(out).run({
      'title': 'Provence',
      'content': '# Landschaft\n- Lavendel\n- Bild-Idee: lavender fields at sunset\n\n# Essen\n- Ratatouille\n![market with vegetables](auto)',
    }, ToolContext(onArtifact: arts.add));
    check(prompts.length == 2 && prompts.first.startsWith('lavender fields'), 'zwei Bilder erzeugt ($prompts)');
    check(r.contains('2 Bildern') && arts.where((a) => a.kind == 'image').length == 2 && arts.any((a) => a.kind == 'pptx'), 'Bilder in Präsentation ($r)');
    final none = await autoImages(OutputSpace(dir), '![x](auto)', ToolContext());
    check(none.$2 == 0, 'ohne Bildmodell nichts erzeugen');
  });

  await group('KI-Kennzeichnung und Bilder in Folien', () async {
    // EU-Symbol wird ins Bild gestempelt (unten rechts dunkel, oben links unverändert)
    const w = 512, h = 512;
    final rgba = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
    stampAiLabel(rgba, w, h);
    int lum(int x, int y) => rgba[(y * w + x) * 4];
    var dark = 0;
    for (var y = h - 30; y < h; y++) {
      for (var x = w - 90; x < w; x++) {
        if (lum(x, y) < 60) dark++;
      }
    }
    var darkElsewhere = 0;
    for (var y = 0; y < h - 30; y++) {
      for (var x = 0; x < w; x++) {
        if (lum(x, y) < 250) darkElsewhere++;
      }
    }
    check(dark > 300 && darkElsewhere == 0, 'EU-Symbol klein in der Ecke ($dark dunkle Pixel, sonst unverändert)');
    final png = encodePngRgba(w, h, rgba, text: aiImageMetadata(prompt: 'lavender fields'));
    check(latin1.decode(png, allowInvalid: true).contains('AI-Generated') && latin1.decode(png, allowInvalid: true).contains('EU AI Act'),
        'Maschinenlesbare Kennzeichnung (PNG tEXt)');

    // Vorher erzeugte Bilder landen auf Folien ohne Bild
    final md = placeImages('# Einleitung\n- a\n- b\n# Markt\n![x](da.png)\n# Ausblick\n- c\n# Fragen\n- ?',
        files: ['/x/bild1.png', '/x/bild2.png'], auto: false, maxAuto: 3);
    check(md.contains('# Einleitung\n- a\n- b\n\n![Einleitung](bild1.png)') && md.contains('![Ausblick](bild2.png)'), 'Bilder auf Folien verteilt');
    check(!md.split('# Fragen')[1].contains('!['), 'Fragen-Folie bleibt ohne Bild');
    final auto = placeImages('# A\n- x\n# B\n- y', files: const [], auto: true, maxAuto: 1);
    check(auto.contains('![A](auto)') && !auto.contains('![B]'), 'gewünschte Bilder: auto, höchstens maxAuto');
    check(wantsImages('Erstelle eine PowerPoint mit Bildern über Wien') && !wantsImages('Erstelle eine Präsentation über Wien'), 'Wunsch nach Bildern erkannt');

    // Ende zu Ende: generate_image, dann create_presentation ohne Bildverweis
    final dir = Directory.systemTemp.createTempSync('ae_ki');
    final one = encodePngRgba(4, 4, Uint8List(64)..fillRange(0, 64, 200));
    var n = 0;
    final gen = (String p, String f, String neg) async => (File('${dir.path}/KI-Bild ${n++}.png')..writeAsBytesSync(one)).path;
    final out = OutputSpace(dir, imageGenerator: () => gen);
    final ctx = ToolContext()..userRequest = 'Mach eine PowerPoint über Wien mit Bildern';
    await GenerateImageTool(gen).run({'prompt': 'vienna skyline'}, ctx);
    final r = await CreatePresentationTool(out).run({'title': 'Wien', 'content': '# Stadt\n- Stephansdom\n# Kultur\n- Oper'}, ctx);
    final pptx = File('${dir.path}/Wien.pptx').readAsBytesSync();
    final s = latin1.decode(pptx, allowInvalid: true);
    check(r.contains('2 Bildern') && s.contains('ppt/media/'), 'Bilder stecken in der PowerPoint ($r)');
    check(n == 2, 'zweite Folie bekommt ein neu erzeugtes Bild');
  });

  await group('Websuche: vereinfachte Anfrage und Rückfall', () async {
    final q = WebSearchTool.simplifyQuery('Suche bitte aktuelle Nvidia Aktie Kurs 22.11.2026 "heute" site:finanzen.net');
    check(q == 'Nvidia Aktie Kurs', 'vereinfacht ($q)');
    const feed = '<rss><channel><item><title>Nvidia steigt</title><link>https://example.com/n</link></item></channel></rss>';
    final (hits, used, _) = await WebSearchTool.searchAllEngines('Nvidia Aktie', (u) async => u.host == 'news.google.com' ? feed : '<html></html>');
    check(hits.length == 1 && used == 'Google News', 'Rückfall auf Google News ($used)');
  });

  await group('Suche auf Webseiten (Shops)', () async {
    const amazon = '''<html><body>
<div data-component-type="s-search-result" data-asin="A1"><a href="/dp/A1"><img class="s-image" src="https://m.media-amazon.com/1.jpg"></a>
<h2><a href="/Brotkasten-XL/dp/A1"><span>Brotkasten XL aus Edelstahl, spülmaschinenfest</span></a></h2>
<span class="a-price"><span class="a-offscreen">29,99&nbsp;€</span></span></div>
<div data-component-type="s-search-result" data-asin="A2"><img class="s-image" src="https://m.media-amazon.com/2.jpg">
<h2><a href="/Brotbox/dp/A2"><span>Brotbox Bambus für Familie mit Deckel</span></a></h2>
<span class="a-price"><span class="a-offscreen">24,90 €</span></span></div>
</body></html>''';
    final items = extractPageItems(amazon, Uri.parse('https://www.amazon.de/s?k=brotdose'));
    check(items.length == 2 && items[0].title.contains('Brotkasten XL') && items[0].summary.contains('29,99'),
        'Amazon-Ergebnisse mit Preis (${items.map((i) => '${i.title}|${i.summary}').join(' / ')})');
    check(items[0].link == 'https://www.amazon.de/Brotkasten-XL/dp/A1' && items[0].image.endsWith('1.jpg'), 'Link und Bild');

    final urls = <String>[];
    final tool = SiteSearchTool(fetcher: (u) async {
      urls.add(u.toString());
      if (u.host.contains('amazon')) return '<html>Geben Sie die unten angezeigten Zeichen ein api-services-support@amazon.com</html>'.isEmpty ? '' : throw ToolException('www.amazon.de: blockiert automatische Abrufe (Captcha)');
      if (u.host.contains('geizhals')) {
        return '<article><a href="/brotkasten-a1.html"><h3>Wesco Brotkasten Grandy</h3></a><span>ab € 59,90</span></article>'
            '<article><a href="/brotbox-a2.html"><h3>Zassenhaus Brotbox Edelstahl</h3></a><span>ab € 34,99</span></article>'
            '<article><a href="/a3.html"><h3>Emsa Brotkasten Fresh Box</h3></a><span>€ 19,99</span></article>';
      }
      return '';
    });
    final out = await tool.run({'site': 'amazon', 'query': 'brotdose spülmaschinenfest'}, ToolContext(requestNetwork: (_) async => true));
    check(urls.first.startsWith('https://www.amazon.de/s?k=brotdose') && out.contains('blockiert') && out.contains('geizhals.at') &&
        out.contains('Wesco Brotkasten') && out.contains('59,90'), 'Amazon blockiert → automatisch Geizhals ($out)');

    check(cleanLink('https://www.amazon.de/sspa/click?ie=UTF8&spc=MTo&url=%2FBlockh%C3%BCtte-Brotdose%2Fdp%2FB07SR49JCG%2Fref%3Dsr_1_1_sspa&x=1')
            == 'https://www.amazon.de/Blockh%C3%BCtte-Brotdose/dp/B07SR49JCG' &&
        cleanLink('https://www.amazon.de/Brotkasten-XL/dp/B0ABCDEFGH/ref=sr_1_2?keywords=x') == 'https://www.amazon.de/Brotkasten-XL/dp/B0ABCDEFGH' &&
        cleanLink('https://geizhals.at/a1.html') == 'https://geizhals.at/a1.html', 'Werbe- und Tracking-Links gekürzt');

    // Fußzeile mit App-Store-Badges ist kein Suchergebnis
    const badges = '<html><body><main><p>Keine Treffer</p></main><footer>'
        '<a href="https://apps.apple.com/at/app/geizhals/id1"><img src="/apple.png" alt="App Store"></a>'
        '<a href="https://play.google.com/store/apps/details?id=x"><img src="/play.png" alt="Google Play"></a>'
        '<a href="https://appgallery.huawei.com/app/C1"><img src="/hw.png" alt="Huawei AppGallery"></a></footer>'
        '<a href="https://apps.apple.com/x"><img src="/a.png" alt="App Store"></a></body></html>';
    final junk = extractPageItems(badges, Uri.parse('https://geizhals.at/?fs=brotdose'));
    check(junk.isEmpty, 'App-Store-Links werden ignoriert (${junk.map((i) => i.title)})');
    final rel = relevantItems([PageItem('Wesco Brotdose Edelstahl', 'https://geizhals.at/a1.html', ''),
      PageItem('Gutscheine und Aktionen', 'https://geizhals.at/aktion', '')], 'Brotdose spülmaschinenfest Familie');
    check(rel.length == 1 && rel.first.title.startsWith('Wesco'), 'nur passende Treffer');

    // Amazon gesperrt, Suchmaschine liefert Amazon-Links → diese zuerst
    final viaDdg = await SiteSearchTool(fetcher: (u) async {
      if (u.host.contains('amazon')) throw ToolException('www.amazon.de: blockiert automatische Abrufe (Captcha)');
      if (u.host.contains('duckduckgo') && u.queryParameters['q']!.startsWith('site:amazon.de')) {
        return '<div class="result__body"><a class="result__a" href="https://www.amazon.de/Brotkasten-Familie/dp/B01">Brotkasten für Familien</a>'
            '<a class="result__snippet">spülmaschinenfest</a></div>'
            '<div class="result__body"><a class="result__a" href="https://apps.apple.com/x">Amazon Shopping App</a></div>';
      }
      return '';
    }).run({'site': 'amazon.de', 'query': 'Brotdose Brotkasten spülmaschinenfest'}, ToolContext(requestNetwork: (_) async => true));
    final dc = parseResultCards(viaDdg);
    check(dc.length == 1 && dc.first.link.contains('amazon.de/Brotkasten') && viaDdg.contains('blockiert'),
        'Amazon-Links über Suchmaschine ($viaDdg)');

    // Unbekannte Seite: Suchfeld der Startseite finden
    const home = '<html><form action="/suche" method="get"><input type="hidden" name="lang" value="de">'
        '<input type="search" name="begriff" placeholder="Suchen"></form></html>';
    final u = searchUrlFromForm(home, Uri.parse('https://www.beispiel.at/'), 'Brot dose');
    check(u.toString() == 'https://www.beispiel.at/suche?lang=de&begriff=Brot+dose', 'Suchfeld erkannt ($u)');
    check(searchUrlFromForm('<form method="post"><input name="q"></form>', Uri.parse('https://x.at/'), 'a') == null,
        'POST-Formulare werden nicht benutzt');
    check(normalizeSite('https://www.Geizhals.at/abc') == 'geizhals.at' && normalizeSite('amazon') == 'amazon.de', 'Seitennamen');

    check(detectBlockPage('<div class="anomaly-modal">') != null && detectBlockPage('<h1>Hallo</h1>') == null, 'Bot-Sperre erkannt');
    final bing = WebSearchTool.parseBing('<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?!&&u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS9h&ntb=1">'
        'Beispiel</a></h2><p>Kurztext</p></li>');
    check(bing.length == 1 && bing.first.url == 'https://example.com/a' && bing.first.snippet == 'Kurztext', 'Bing-Treffer');
    final ws = WebSearchTool(fetcher: (u) async => u.host.contains('duckduckgo') ? throw ToolException('Captcha') : '');
    final r = await ws.run({'query': 'x'}, ToolContext(requestNetwork: (_) async => true));
    check(r.contains('DuckDuckGo: ') && r.contains('Captcha') && r.contains('Grund'), 'Websuche nennt den Grund');
  });

  await group('Antwort ohne Vorspann', () async {
    const q = 'Wie wird das Wetter morgen in Wien?';
    check(stripAnswerPreamble('Du fragst, wie das Wetter morgen in Wien wird. Morgen wird es sonnig.', q) == 'Morgen wird es sonnig.',
        'wiederholte Frage entfernt');
    check(stripAnswerPreamble('Der Nutzer möchte das Wetter wissen. Ich sollte nachsehen. Morgen 12 Grad.', q) == 'Morgen 12 Grad.',
        'lautes Denken entfernt');
    check(stripAnswerPreamble('Morgen wird es sonnig.', q) == 'Morgen wird es sonnig.', 'normale Antwort bleibt');
    check(stripAnswerPreamble('Du fragst nach', q, done: false) == null, 'unklarer Anfang: warten');
    check(stripAnswerPreamble('Die wichtigsten Sportnachrichten sind: Rapid gewinnt.', 'Welche Sportnews gibt es auf krone.at?') ==
        'Die wichtigsten Sportnachrichten sind: Rapid gewinnt.', 'Einleitung mit neuer Info bleibt');
  });

  await group('Browser', () async {
    final d = _FakeBrowser();
    final tool = BrowserTool(() => d);
    final ctx = ToolContext(requestNetwork: (_) async => true);
    var out = await tool.run({'action': 'open', 'target': 'shop.example', 'text': ''}, ctx);
    check(d.opened.single == 'https://shop.example' && d.shown && out.contains('[1] Suchfeld „Suche“') &&
        out.contains('[3] Knopf „Jetzt kaufen“') && out.contains('Wesco Brotkasten'), 'Seite öffnen und lesen ($out)');
    check(!out.contains('App Store'), 'App-Store-Karten gefiltert');
    final cards = parseResultCards(out);
    check(cards.length == 1 && cards.first.price == '€ 59,90', 'Karten aus dem Browser (${cards.map((c) => c.toJson())})');
    out = await tool.run({'action': 'type', 'target': '1', 'text': 'Brotdose'}, ctx);
    check(d.scripts.any((s) => s.contains('"Brotdose"')) && d.settled == 2, 'Text eingeben');
    d.allow = false;
    out = await tool.run({'action': 'click', 'target': '[3]', 'text': ''}, ctx);
    check(d.handOvers == 1 && d.confirms == 0 && !d.scripts.any((s) => s.contains('"click"')) && out.contains('Zahlung'),
        'Kaufen/Zahlen: Junels übergibt an den Nutzer und klickt nie');
    out = await tool.run({'action': 'type', 'target': '2', 'text': 'geheim'}, ctx);
    check(d.handOvers == 2 && !d.scripts.any((s) => s.contains('geheim')), 'Passwort gibt der Nutzer selbst ein');
    check(out.contains('ANMELDUNG'), 'Passwortfeld → Hinweis Anmeldeseite');
    d.captcha = true;
    out = await tool.run({'action': 'search', 'target': 'beispielshop.at', 'text': 'Brot'}, ctx);
    check(d.handOvers == 3 && out.contains('Suchfeld [1] ausgefüllt'), 'Captcha → Nutzer übernimmt, dann Suche ($out)');
    check(looksLikeLogin({'url': 'https://www.id-austria.gv.at/authHandler', 'els': const [], 'text': ''}) &&
            !looksLikeLogin({'url': 'https://www.oesterreich.gv.at/de/landingpages/urkunden', 'els': const [], 'text': 'Urkunden bestellen'}),
        'Anmeldeseite erkennen (ID Austria ja, Urkundenseite nein)');
    out = await tool.run({'action': 'search', 'target': 'amazon', 'text': 'Brot dose'}, ctx);
    check(d.opened.last.startsWith('https://www.amazon.de/s?k=Brot+dose'), 'bekannte Shops direkt über die Such-Adresse');
    final noApp = BrowserTool(() => null);
    var err = '';
    try {
      await noApp.run({'action': 'read', 'target': '', 'text': ''}, ctx);
    } on ToolException catch (e) {
      err = e.message;
    }
    check(err.contains('nur verfügbar'), 'ohne geöffnete App klare Meldung');
  });

  await group('Ergebnis-Karten', () async {
    const obs = '''Suchergebnisse auf geizhals.at für „brotdose“ (https://geizhals.at/?fs=brotdose):
- Wesco Brotkasten Grandy
  Preis: ab € 59,90 · Edelstahl, 3 Farben
  Bild: https://gzhls.at/1.jpg
  Link: https://geizhals.at/a1.html
- Emsa Fresh Box
  Link: https://geizhals.at/a3.html
- Ohne Link

Die Treffer sieht der Nutzer bereits als Karten.''';
    final c = parseResultCards(obs);
    check(c.length == 2 && c[0].title == 'Wesco Brotkasten Grandy' && c[0].price == 'ab € 59,90' && c[0].image.endsWith('1.jpg') &&
        c[0].note == 'Edelstahl, 3 Farben' && c[1].link.endsWith('a3.html'), 'Karten aus Werkzeug-Ausgabe (${c.map((x) => x.toJson())})');
    final hits = List.generate(14, (i) => '<div class="result__body"><a class="result__a" href="https://s$i.example/x">Treffer $i</a>'
        '<a class="result__snippet">Text $i</a></div>').join();
    final ws = await WebSearchTool(fetcher: (u) async => hits).run({'query': 'q'}, ToolContext(requestNetwork: (_) async => true));
    final cut = ws.indexOf(moreCardsMarker);
    check(cut > 0 && !ws.substring(0, cut).contains('Treffer 6') && ws.substring(cut).contains('Treffer 13'),
        'Websuche: 6 Treffer fürs Modell, Rest nur als Karten');
    final wc = parseResultCards(ws);
    check(wc.length == 14 && wc.first.note == 'Text 0' && wc.first.link == 'https://s0.example/x', 'alle Treffer als Karten (${wc.length})');
    final page = await WebFetchTool(fetcher: (u) async => '<html><head><title>Wiener Linien</title>'
            '<meta property="og:image" content="/og.png"><meta name="description" content="Fahrplan und Störungen"></head>'
            '<body><p>Inhalt</p></body></html>')
        .run({'url': 'https://www.wienerlinien.at/'}, ToolContext(requestNetwork: (_) async => true));
    final pc = parseResultCards(page);
    check(pc.length == 1 && pc.first.image == 'https://www.wienerlinien.at/og.png' && pc.first.note == 'Fahrplan und Störungen',
        'einzelne Seite als Karte');
  });

  await group('Wetter und Nachrichten', () async {
    final calls = <String>[];
    final weather = WeatherTool(
      defaultLocation: () => 'Wien',
      fetcher: (u) async {
        calls.add(u.host);
        if (u.host.startsWith('geocoding')) {
          return '{"results":[{"name":"Wien","latitude":48.2,"longitude":16.37,"country":"Österreich","admin1":"Wien"}]}';
        }
        return '{"current":{"temperature_2m":7.4,"apparent_temperature":4.1,"weather_code":61,"wind_speed_10m":18,'
            '"relative_humidity_2m":80},"daily":{"time":["2026-11-20","2026-11-21"],"weather_code":[61,3],'
            '"temperature_2m_max":[9,8],"temperature_2m_min":[3,2],"precipitation_probability_max":[70,20],'
            '"precipitation_sum":[4.2,0],"sunrise":["2026-11-20T07:18","2026-11-21T07:19"],"sunset":["2026-11-20T16:10","2026-11-21T16:09"]}}';
      },
    );
    var asked = '';
    final wctx = ToolContext(requestNetwork: (p) async {
      asked = p;
      return true;
    });
    final out = await weather.run({'location': '', 'days': 2}, wctx);
    check(out.contains('Wien') && out.contains('7 °C') && out.contains('leichter Regen') && out.contains('Morgen (Sa 21.11.): bedeckt'),
        'Wetter mit Heimatort, Codes übersetzt ($out)');
    check(wctx.answerNow && out.contains('Heute ist'), 'Wetter: danach direkt antworten, Datum dabei');
    check(newsSection('Welche Sport News gibt es auf orf.at') == 'sport' && newsSection('Wetter morgen') == null,
        'Ressort Sport erkannt');
    final fetchedNews = <String>[];
    final sportOut = await NewsTool(fetcher: (u) async {
      fetchedNews.add(u.toString());
      return '<rss><channel><item><title>Rapid gewinnt Derby</title><link>https://sport.orf.at/1</link>'
          '<description>Fußball</description></item></channel></rss>';
    }).run({'topic': 'Sport', 'source': 'orf', 'count': 5}, ToolContext(requestNetwork: (_) async => true));
    check(fetchedNews.single == 'https://rss.orf.at/sport.xml' && sportOut.contains('Rapid gewinnt Derby') &&
        !sportOut.contains('keine Meldung'), 'Sport-Nachrichten aus dem Sport-Feed ($fetchedNews)');
    check(asked.contains('Wien') && calls.length == 2, 'Internet-Freigabe gefragt, 2 Abrufe');

    const rss = '''<?xml version="1.0"?><rss><channel>
<item><title>OpenAI stellt neues Modell vor</title><link>https://futurezone.at/a</link><description>KI-News</description></item>
<item><title>Fußball: Rapid gewinnt</title><link>https://futurezone.at/b</link></item>
<item><title>Neue Chips von Nvidia</title><link>https://futurezone.at/c</link></item>
</channel></rss>''';
    final news = NewsTool(fetcher: (u) async => rss);
    final n1 = await news.run({'topic': 'KI', 'source': 'auto', 'count': 5}, ToolContext(requestNetwork: (_) async => true));
    check(n1.contains('OpenAI stellt') && n1.contains('Nvidia') && !n1.contains('Rapid'), 'KI-Thema gefiltert (Synonyme)');
    check(n1.contains('futurezone') || n1.contains('heise'), 'Tech-Quellen bei KI');
    final n2 = await news.run({'topic': 'Weltraum'}, ToolContext(requestNetwork: (_) async => true));
    check(n2.contains('keine Meldung') && n2.contains('Rapid'), 'kein Treffer → allgemeine Meldungen');
    var denied = false;
    try {
      await news.run({}, ToolContext(requestNetwork: (_) async => false));
    } catch (_) {
      denied = true;
    }
    check(denied, 'ohne Freigabe kein Abruf');
  });

  await group('Gerät: E-Mail, WhatsApp, Anruf, Kalender, Dateien', () async {
    final dev = _FakeDevice();
    final ctx = ToolContext();
    var r = await EmailTool(dev).run({'to': 'Anna', 'subject': 'Treffen', 'body': 'Hallo Anna'}, ctx);
    check(dev.log.last == 'mail:anna@example.com|Treffen|Hallo Anna' && r.contains('Senden'), 'E-Mail an Kontakt per Name');
    await WhatsAppTool(dev).run({'to': 'Anna', 'text': 'Komme 10 min später'}, ctx);
    check(dev.log.last == 'wa:436641234567|Komme 10 min später', 'WhatsApp: Nummer international ($dev.log)');
    // Mit Karten: Entwurf statt sofort öffnen
    final proposed = <Map<String, String>>[];
    final before = dev.log.length;
    final pctx = ToolContext(propose: proposed.add);
    r = await EmailTool(dev).run({'to': 'Anna', 'subject': 'Treffen', 'body': 'Hallo Anna'}, pctx);
    await WhatsAppTool(dev).run({'to': 'Anna', 'text': 'Bin unterwegs'}, pctx);
    check(dev.log.length == before && proposed.length == 2 && proposed[0]['to'] == 'anna@example.com' &&
        proposed[0]['status'] == 'pending' && proposed[1]['to'] == '436641234567' && r.contains('Soll ich das senden') &&
        pctx.answerNow, 'E-Mail/WhatsApp als Freigabe-Karte ($proposed)');
    await CallTool(dev).run({'to': '+43 1 234'}, ctx);
    check(dev.log.last == 'dial:+43 1 234', 'Anruf mit Nummer');
    var multi = '';
    try {
      await CallTool(dev).run({'to': 'Max'}, ctx);
    } on ToolException catch (e) {
      multi = e.message;
    }
    check(multi.contains('Max Muster') && multi.contains('Max Mayer'), 'mehrere Kontakte → Rückfrage');
    final now = DateTime(2026, 11, 20, 7, 0);
    await CalendarAddTool(dev, clock: () => now).run({'title': 'Zahnarzt', 'start': 'morgen 9:30', 'duration_minutes': 45}, ctx);
    check(dev.log.last == 'cal:Zahnarzt|2026-11-21 09:30|2026-11-21 10:15|false', 'Termin mit Dauer (${dev.log.last})');
    await CalendarAddTool(dev, clock: () => now).run({'title': 'Urlaub', 'start': '2026-12-24'}, ctx);
    check(dev.log.last.endsWith('|true') && dev.log.last.contains('2026-12-24 00:00'), 'nur Datum → ganztägig');
    r = await CalendarListTool(dev, clock: () => now).run({'day': 'heute'}, ctx);
    check(r.contains('09:00–10:00 Team-Meeting (Büro)') && r.contains('Freitag'), 'Termine heute ($r)');
    check(dev.log.last == 'list:2026-11-20 00:00-2026-11-21 00:00', 'Zeitraum heute');
    final (f, t) = parseDayRange('Montag', 1, now);
    check(f == DateTime(2026, 11, 23) && t == DateTime(2026, 11, 24), 'Wochentag → nächster Montag');
    check(normalizePhone('0664 123', '43') == '43664123' && normalizePhone('+49 30 1', '43') == '49301', 'Nummern normalisieren');
    dev.allow = false;
    r = await FileRenameTool(dev).run({'path': '/Users/c/Docs/a.pdf', 'new_name': 'Rechnung.pdf'}, ctx);
    check(r.contains('abgelehnt') && !dev.log.last.startsWith('rename'), 'Umbenennen nur nach Bestätigung');
    dev.allow = true;
    r = await FileMoveTool(dev).run({'path': '/Users/c/Docs/a.pdf', 'folder': '/Users/c/Docs/Rechnungen'}, ctx);
    check(dev.log.last == 'move:/Users/c/Docs/a.pdf>/Users/c/Docs/Rechnungen', 'Verschieben nach Bestätigung');
  });

  await group('Denk-Text und Marker entfernen', () async {
    check(cleanModelText('15 % von 2.340 € ist 351 €.<channel|>351 €') == '351 €', 'Gemma 4: nur Text nach <channel|>');
    check(cleanModelText('<|channel>thought\nIch überlege …<channel|>Hallo!') == 'Hallo!', 'Gemma 4: Gedankenblock');
    check(cleanModelText('<|channel>thought\nIch überl', streaming: true) == '', 'Streaming: Gedanke wird nicht gezeigt');
    check(cleanModelText('<think>hmm</think>\nAntwort') == 'Antwort', 'Qwen <think>');
    check(cleanModelText('Antwort<end_of_turn>') == 'Antwort', 'Endmarker');
    check(skipThinking('<|turn>user\nhi<turn|>\n<|turn>model\n').endsWith('<|channel>thought\n<channel|>'),
        'Gemma 4: leerer Gedanke im Prompt');
    check(skipThinking('<|im_start|>assistant\n') == '<|im_start|>assistant\n', 'andere Modelle unverändert');
  });

  await group('Abgleich: Kryptografie', () async {
    check(hexOf(sha256(utf8.encode('abc'))) == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'SHA-256 (abc)');
    check(hexOf(sha256(utf8.encode('a' * 1000))) == '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3', 'SHA-256 (1000×a)');
    check(hexOf(hmacSha256(List.filled(20, 0x0b), utf8.encode('Hi There'))) ==
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7', 'HMAC-SHA256 (RFC 4231)');
    check(hexOf(pbkdf2(utf8.encode('password'), utf8.encode('salt'), 1, 32)) ==
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b', 'PBKDF2 1 Runde');
    check(hexOf(pbkdf2(utf8.encode('password'), utf8.encode('salt'), 4096, 32)) ==
        'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a', 'PBKDF2 4096 Runden');
    final key = List.generate(32, (i) => i);
    final nonce = [0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0];
    final ct = chacha20(key, nonce, utf8.encode("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."));
    check(hexOf(ct).startsWith('6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d'),
        'ChaCha20 (RFC 8439)');
    final k1 = SyncKeys.fromPassphrase('mein geheimes Passwort', iterations: 1000);
    final k2 = SyncKeys.fromPassphrase('mein geheimes Passwort', iterations: 1000);
    final k3 = SyncKeys.fromPassphrase('anderes', iterations: 1000);
    final sealed = k1.seal('{"hallo":"Wörld"}');
    check(k2.open(sealed) == '{"hallo":"Wörld"}' && k1.account == k2.account, 'gleiches Passwort entschlüsselt');
    var rejected = false;
    try {
      k3.open(sealed);
    } on FormatException {
      rejected = true;
    }
    check(rejected && k3.account != k1.account, 'falsches Passwort abgelehnt');
    check(k1.seal('x') != k1.seal('x'), 'zufällige Nonce');
  });

  await group('Abgleich: zwei Geräte über Hub und WLAN', () async {
    final keys = SyncKeys.fromPassphrase('test', iterations: 100);
    var now = 1000;
    final mac = _MapSource({'chat:1': '{"t":"Hallo"}', 'mem:a': '{"t":"Ich heiße Christoph"}'});
    final phone = _MapSource({'prompt:x': '{"t":"Briefing"}'});
    final hub = SyncHub();
    final eMac = SyncEngine(keys: keys, source: mac, clock: () => now);
    final ePhone = SyncEngine(keys: keys, source: phone, clock: () => now);
    Future<Map<String, dynamic>> viaHub(Map<String, dynamic> r) async =>
        jsonDecode(jsonEncode(hub.handle(r, account: keys.account))) as Map<String, dynamic>;

    var r = await eMac.syncWith('hub', viaHub);
    check(r.sent == 2 && r.received == 0, 'Mac sendet 2 ($r)');
    now += 10;
    r = await ePhone.syncWith('hub', viaHub);
    check(r.sent == 1 && r.received == 2 && phone.data.length == 3, 'Handy bekommt Chat + Notiz ($r)');
    now += 10;
    r = await eMac.syncWith('hub', viaHub);
    check(r.received == 1 && mac.data['prompt:x'] == '{"t":"Briefing"}', 'Mac bekommt Prompt ($r)');
    // erneuter Abgleich ohne Änderungen: nichts zu tun
    r = await eMac.syncWith('hub', viaHub);
    check(r.sent == 0 && r.received == 0, 'keine Änderungen → nichts übertragen ($r)');
    // Handy ändert Chat und löscht Notiz
    now += 10;
    phone.data['chat:1'] = '{"t":"Hallo, geändert"}';
    phone.data.remove('mem:a');
    r = await ePhone.syncWith('hub', viaHub);
    check(r.sent == 2, 'Änderung und Löschung gesendet ($r)');
    now += 10;
    r = await eMac.syncWith('hub', viaHub);
    check(mac.data['chat:1'] == '{"t":"Hallo, geändert"}' && !mac.data.containsKey('mem:a'), 'Mac übernimmt Änderung und Löschung');
    // Konflikt: beide ändern, neuere gewinnt
    now += 10;
    mac.data['prompt:x'] = '{"t":"Mac-Version"}';
    await eMac.syncWith('hub', viaHub);
    now += 10;
    phone.data['prompt:x'] = '{"t":"Handy-Version (neuer)"}';
    await ePhone.syncWith('hub', viaHub);
    now += 10;
    await eMac.syncWith('hub', viaHub);
    await ePhone.syncWith('hub', viaHub);
    check(mac.data['prompt:x'] == '{"t":"Handy-Version (neuer)"}' && phone.data['prompt:x'] == mac.data['prompt:x'],
        'Konflikt: neuere Änderung gewinnt auf beiden Geräten');
    check(hub.items.values.every((i) => !i.b.contains('Handy') && !i.b.contains('Hallo')), 'Hub sieht nur verschlüsselte Daten');

    // WLAN: Handy stellt bereit, Mac verbindet sich per HTTP
    final hub2 = SyncHub();
    final lanPhone = SyncEngine(keys: keys, source: phone, clock: () => now);
    final host = LanSyncHost(
      account: keys.account,
      name: 'Testhandy',
      port: 47391,
      onRequest: (req) async {
        await lanPhone.syncWith('local', (q) async => hub2.handle(q, account: keys.account));
        final resp = hub2.handle(req, account: keys.account);
        unawaited(Future<void>.delayed(const Duration(milliseconds: 50),
            () => lanPhone.syncWith('local', (q) async => hub2.handle(q, account: keys.account))));
        return resp;
      },
    );
    await host.start();
    try {
      final fresh = _MapSource({'chat:neu': '{"t":"vom Mac"}'});
      final eFresh = SyncEngine(keys: keys, source: fresh, clock: () => now);
      final url = Uri.parse('http://127.0.0.1:47391/junels-sync');
      r = await eFresh.syncWith('lan', (q) => syncHttpPost(url, q));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      check(fresh.data['prompt:x'] == phone.data['prompt:x'] && phone.data['chat:neu'] == '{"t":"vom Mac"}',
          'WLAN: beide Richtungen übertragen ($r)');
      var denied = false;
      try {
        await SyncEngine(keys: SyncKeys.fromPassphrase('falsch', iterations: 100), source: _MapSource({}))
            .syncWith('lan', (q) => syncHttpPost(url, q));
      } on SyncException catch (e) {
        denied = e.message.contains('403') || e.message.contains('Passwort');
      }
      check(denied, 'WLAN: falsches Passwort abgewiesen');
    } finally {
      await host.stop();
    }
  });

  final syncUrl = Platform.environment['AE_TEST_SYNC_URL'] ?? '';
  if (syncUrl.isNotEmpty) {
    await group('Abgleich: PHP-Server', () async {
      final keys = SyncKeys.fromPassphrase('php-test-${DateTime.now().microsecondsSinceEpoch}', iterations: 100);
      final url = Uri.parse(syncUrl);
      final a = _MapSource({'chat:1': '{"t":"Hallo vom Mac"}', 'mem:x': '{"t":"Notiz"}'});
      final b = _MapSource({'prompt:p': '{"t":"Briefing"}'});
      final ea = SyncEngine(keys: keys, source: a);
      final eb = SyncEngine(keys: keys, source: b);
      var r = await ea.syncWith('srv', (q) => syncHttpPost(url, q));
      check(r.sent == 2, 'Mac → Server ($r)');
      r = await eb.syncWith('srv', (q) => syncHttpPost(url, q));
      check(r.received == 2 && b.data['chat:1'] == '{"t":"Hallo vom Mac"}', 'Handy ← Server ($r)');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      b.data.remove('mem:x');
      await eb.syncWith('srv', (q) => syncHttpPost(url, q));
      r = await ea.syncWith('srv', (q) => syncHttpPost(url, q));
      check(a.data['prompt:p'] == '{"t":"Briefing"}' && !a.data.containsKey('mem:x'), 'Prompt und Löschung beim Mac ($r)');
      var denied = false;
      try {
        await SyncEngine(keys: SyncKeys.fromPassphrase('fremd', iterations: 100), source: _MapSource({}))
            .syncWith('srv', (q) => syncHttpPost(url, q));
      } on SyncException catch (e) {
        denied = e.message.contains('403');
      }
      check(denied, 'fremdes Konto abgewiesen (Server an erstes Konto gebunden)');
    });
  }

  await group('Sprechpausen-Erkennung (VAD)', () async {
    final vad = VoiceActivityDetector();
    Float32List noise(int ms, double amp) =>
        Float32List.fromList(List.generate(16 * ms, (i) => amp * math.sin(i * 0.37) * (i % 7 - 3) / 3));
    Float32List tone(int ms) => Float32List.fromList(List.generate(16 * ms, (i) => 0.3 * math.sin(i * 2 * math.pi * 220 / 16000)));
    final events = <VadEvent>[];
    for (final chunk in [noise(1000, 0.002), tone(1200), noise(1200, 0.002)]) {
      for (var i = 0; i < chunk.length; i += 1600) {
        final e = vad.add(Float32List.sublistView(chunk, i, math.min(chunk.length, i + 1600)));
        if (e != VadEvent.none) events.add(e);
      }
    }
    check(events.length == 2 && events[0] == VadEvent.speechStart && events[1] == VadEvent.speechEnd,
        'Start und Ende erkannt ($events)');
    final u = vad.takeUtterance();
    check(u.length > 16000 * 1.1 && u.length < 16000 * 2.4, 'Äußerung ${(u.length / 16000).toStringAsFixed(2)} s inkl. Vorlauf');
    final vad2 = VoiceActivityDetector();
    var any = false;
    for (final chunk in [noise(800, 0.002), tone(120), noise(1500, 0.002)]) {
      if (vad2.add(chunk) == VadEvent.speechEnd) any = true;
    }
    check(!any, 'kurzes Klicken (120 ms) zählt nicht als Sprache');
    final vad3 = VoiceActivityDetector()..extraMarginDb = 40;
    var started = false;
    for (final chunk in [noise(800, 0.002), tone(1000)]) {
      if (vad3.add(chunk) == VadEvent.speechStart) started = true;
    }
    check(!started, 'erhöhte Schwelle (Agent spricht) ignoriert leises Echo');
    Float32List toneA(int ms, double amp) =>
        Float32List.fromList(List.generate(16 * ms, (i) => amp * math.sin(i * 2 * math.pi * 220 / 16000)));
    List<VadEvent> feed(VoiceActivityDetector v, List<Float32List> chunks) {
      final ev = <VadEvent>[];
      for (final c in chunks) {
        for (var i = 0; i < c.length; i += 480) {
          final e = v.add(Float32List.sublistView(c, i, math.min(c.length, i + 480)));
          if (e != VadEvent.none) ev.add(e);
        }
      }
      return ev;
    }

    // Klassifikator: lauter Lärm ohne Sprache startet nichts
    final vad4 = VoiceActivityDetector(classifier: (_) => false);
    check(feed(vad4, [noise(500, 0.002), noise(1500, 0.3)]).isEmpty, 'Lärm ohne Sprache (Klassifikator) ignoriert');
    // Nahfeld: nach eigener lauter Äußerung lösen leisere Stimmen (-26 dB) nichts aus
    final vad5 = VoiceActivityDetector(nearFieldDb: 15);
    final e5 = feed(vad5, [noise(500, 0.002), toneA(1200, 0.4), noise(1200, 0.002)]);
    vad5.takeUtterance();
    final e5b = feed(vad5, [toneA(1500, 0.02), noise(1200, 0.002)]);
    check(e5.length == 2 && e5b.isEmpty, 'leise Hintergrundstimme ignoriert ($e5 / $e5b)');
    // Nahfeld: Stimme im Hintergrund während man selbst spricht verlängert nicht
    final vad6 = VoiceActivityDetector(nearFieldDb: 15);
    final e6 = feed(vad6, [noise(400, 0.002), toneA(1500, 0.4), toneA(3000, 0.02)]);
    check(e6.contains(VadEvent.speechEnd), 'Ende trotz leiser Stimmen im Hintergrund');
    // Absender-Modus: Pausen beenden nicht, erst finish()
    final vad7 = VoiceActivityDetector()..manual = true;
    final e7 = feed(vad7, [noise(400, 0.002), toneA(800, 0.3), noise(3000, 0.002), toneA(800, 0.3), noise(2000, 0.002)]);
    check(e7.length == 1 && e7.single == VadEvent.speechStart, 'Absender-Modus: Pause beendet nicht ($e7)');
    check(vad7.finish(), 'finish() schließt ab');
    final u7 = vad7.takeUtterance();
    check(u7.length > 16000 * 6, 'ganze Äußerung mit Pausen (${(u7.length / 16000).toStringAsFixed(1)} s)');
    check(!vad7.finish(), 'finish() ohne Sprache → false');
  });

  await group('Dokumente: Markdown, PDF, PPTX, PNG', () async {
    final blocks = parseMarkdown('# T\nText **fett**\n\n- a\n  - b\n1. c\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n![Bild](a.png)');
    check(blocks.whereType<MdHeading>().length == 1 && blocks.whereType<MdListItem>().length == 3 &&
        blocks.whereType<MdTable>().single.rows.length == 2 && blocks.whereType<MdImage>().single.src == 'a.png', 'Markdown-Blöcke erkannt');
    check(parseInline('a **b** *c*').where((r) => r.bold).single.text == 'b', 'fett/kursiv inline');
    final rgba = Uint8List(4 * 3 * 2)..fillRange(0, 24, 200);
    final png = encodePngRgba(3, 2, rgba);
    final back = decodePng(png);
    check(back.width == 3 && back.height == 2 && back.rgb[0] == 200 && back.alpha != null, 'PNG schreiben und lesen');
    final tmp = Directory.systemTemp.createTempSync('ae_docs');
    File('${tmp.path}/a.png').writeAsBytesSync(png);
    final out = OutputSpace(tmp);
    final pdf = buildPdfDocument(title: 'Test äöü', markdown: '# H\nText\n\n![x](a.png)\n\n${'Absatz mit viel Text. ' * 400}', resolveImage: out.resolveImage);
    final head = String.fromCharCodes(pdf.sublist(0, 8));
    final pages = RegExp(r'/Type /Page ').allMatches(String.fromCharCodes(pdf)).length;
    check(head.startsWith('%PDF-1.4') && pages >= 2 && String.fromCharCodes(pdf).contains('/XObject'), 'PDF mit $pages Seiten und Bild');
    final s2 = splitSlides('Untertitel\n# A\n- x\n# B\n![](a.png)');
    check(s2.slides.length == 2 && s2.subtitle == 'Untertitel', 'Folien aufgeteilt');
    final pptx = buildPptx(title: 'P', slides: s2.slides, resolveImage: out.resolveImage);
    check(pptx[0] == 0x50 && pptx[1] == 0x4B && String.fromCharCodes(pptx).contains('ppt/slides/slide3.xml'), 'PPTX-Paket mit 3 Folien');
    final arts = <Artifact>[];
    final ctx = ToolContext(onArtifact: arts.add);
    final r1 = await CreateDocumentTool(out).run({'title': 'Bericht', 'content': '# Hallo\nWelt\n![](fehlt.png)'}, ctx);
    check(File('${tmp.path}/Bericht.pdf').existsSync() && r1.contains('fehlt.png'), 'create_document schreibt PDF, meldet fehlendes Bild');
    await CreatePresentationTool(out).run({'title': 'Vortrag', 'content': '# Eins\n- a\n# Zwei\n- b'}, ctx);
    check(File('${tmp.path}/Vortrag.pptx').existsSync() && File('${tmp.path}/Vortrag.pdf').existsSync(), 'create_presentation: PPTX + PDF');

    // Designs & Vorlagen
    check(designForTopic('Präsentation für unsere Reise nach Japan').id == 'reise', 'Design passend zum Thema (Reise)');
    check(designForTopic('Reise nach Venedig am Abend').id == 'reise-nacht' && designForTopic('Wanderreise in Peru').id == 'reise-landschaft' &&
        designForTopic('Reise-Newsletter im Vintage-Look').id == 'reise-vintage', 'Reise-Varianten nach Stimmung');
    final night = readZip(buildPptx(title: 'N', slides: splitSlides('# A\n- x\n# B\n- y\n# C\n- z').slides, design: designById('reise-nacht')));
    check(utf8.decode(night['ppt/slides/slide2.xml']!).contains('14213D') && utf8.decode(night['ppt/slides/slide2.xml']!).contains('star5'),
        'Nacht-Design: dunkler Hintergrund, Sterne');
    final req = 'Design passend zur Reise: https://media.slidesgo.com/storage/1/travel.jpg https://slidesgo.com/de/theme/surat-reisetour-newsletter#x';
    check(designReferencesIn(req).length == 2 && wantsDesign(req), 'Design-Vorlagen-Links erkannt');
    final travel = buildPptx(title: 'Reise', slides: splitSlides('# Anreise\n- a\n# Tag 1\n- b\n# Tag 2\n- c\n# Heimreise\n- d').slides,
        design: designById('reise'), agenda: true);
    final tz = readZip(travel);
    final tAll = tz.entries.where((e) => e.key.endsWith('.xml')).map((e) => utf8.decode(e.value)).join();
    check(tAll.contains('Die Reiseroute') && tAll.contains('0B6E8E') && tz.containsKey('ppt/slides/slide6.xml') && tAll.contains('prstDash'),
        'Reise-Design: Route, Farben, Reiseleiste');
    check(officeText(travel, 'pptx').contains('Tag 1'), 'PowerPoint-Text auslesen');
    final tpl = PptxTemplate.parse(travel)!;
    check(tpl.wide && tpl.theme!.colors['accent1'] != null && tpl.parts.keys.any((k) => k.startsWith('ppt/slideMasters/')), 'PowerPoint-Vorlage gelesen');
    final fromTpl = buildPptx(title: 'Neu', slides: s2.slides, resolveImage: out.resolveImage, template: tpl,
        design: designFromOffice(tpl.theme!, base: designById('standard')));
    final fz = readZip(fromTpl);
    final pres = utf8.decode(fz['ppt/_rels/presentation.xml.rels']!);
    check(pres.contains(tpl.masterPath.substring(4)) && fz.containsKey(tpl.layoutPath) && PptxTemplate.parse(fromTpl) != null,
        'Präsentation auf Basis der Vorlage');
    // Farben aus Beispielbild (über Link mit Vorschaubild)
    final px = Uint8List(4 * 20 * 20);
    for (var i = 0; i < 400; i++) {
      final orange = i % 20 < 8;
      px.setAll(i * 4, orange ? [232, 120, 40, 255] : [20, 90, 140, 255]);
    }
    final sample = encodePngRgba(20, 20, px);
    final fetched = <String>[];
    final dctx = ToolContext(requestNetwork: (_) async => true)..userRequest = req;
    final look = await resolveDesign(
      ctx: dctx,
      topic: 'Reise',
      decodeImage: (b) async {
        final r = decodePng(b);
        final rgba = Uint8List(r.width * r.height * 4);
        for (var i = 0; i < r.width * r.height; i++) {
          rgba.setAll(i * 4, [r.rgb[i * 3], r.rgb[i * 3 + 1], r.rgb[i * 3 + 2], 255]);
        }
        return (r.width, r.height, rgba);
      },
      fetch: (u) async {
        fetched.add(u.toString());
        if (u.host == 'slidesgo.com') {
          return (Uint8List.fromList(utf8.encode('<html><meta property="og:image" content="/img/prev.png"></html>')), 'text/html');
        }
        return (sample, 'image/png');
      },
    );
    check(fetched.contains('https://slidesgo.com/img/prev.png') && look.design.journey && look.design.source != null &&
        {look.design.primary, look.design.secondary}.any((c) => int.parse(c.substring(0, 2), radix: 16) > 0xB0) &&
        {look.design.primary, look.design.secondary}.any((c) => int.parse(c.substring(4, 6), radix: 16) > 0x70),
        'Design aus Beispielbildern: ${look.design.primary}/${look.design.secondary}');
    final denied = await resolveDesign(ctx: ToolContext(requestNetwork: (_) async => false)..userRequest = req, topic: 'Reise');
    check(denied.design.id.startsWith('reise') && denied.notes.any((n) => n.contains('Internet')), 'Ohne Freigabe: Themen-Design, kein Abruf');
    ChartSpec? spec;
    final r3 = await CreateChartTool(out, (s) async {
      spec = s;
      return png;
    }).run({'kind': 'bar', 'title': 'Umsatz', 'labels': 'Jan, Feb', 'values': '10, 20.5; 3, 4', 'series': '2025; 2026'}, ctx);
    check(spec!.series.length == 2 && spec!.series[0].values[1] == 20.5 && spec!.series[1].name == '2026' && r3.contains('Umsatz.png'),
        'create_chart: Reihen und Werte gelesen');
    check(arts.map((a) => a.kind).toList().join(',') == 'pdf,pptx,pdf,image', 'Artefakte für erzeugte Dateien');
    final r4 = await CreateDocumentTool(out).run({'title': 'Bericht', 'content': 'x'}, ctx);
    check(r4.contains('Bericht (2).pdf'), 'gleicher Titel → neuer Dateiname');
    tmp.deleteSync(recursive: true);
  });

  await group('web_fetch: News-Einträge, Bilder, Feeds', () async {
    const page = '''<html><head><title>AI News</title>
<link rel="alternate" type="application/rss+xml" href="/feed.xml"></head><body>
<script>var x = "<a href='/x'><h2>falsch</h2></a>";</script>
<div class="card"><a href="/p/1"><img data-src="/img/1.jpg" alt="Bild 1"><h3>Erste &amp; beste News</h3><p>Kurztext eins</p></a></div>
<div class="card"><a href="https://ext.example.com/2"><div style="background-image:url('https://cdn.example.com/2.png')"></div><h3>Zweite News</h3></a></div>
<a href="/p/3"><h2>Dritte News</h2></a>
<a href="/impressum">Impressum</a>
</body></html>''';
    final items = extractPageItems(page, Uri.parse('https://rtb.li/p/ainews'));
    check(items.length == 3, 'drei Einträge erkannt (${items.length})');
    check(items[0].title == 'Erste & beste News' && items[0].image == 'https://rtb.li/img/1.jpg' &&
        items[0].link == 'https://rtb.li/p/1', 'Titel, Bild (data-src) und Link');
    check(items[1].image == 'https://cdn.example.com/2.png' && items[1].link == 'https://ext.example.com/2', 'Hintergrundbild');
    const rss = '''<?xml version="1.0"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel>
<item><title><![CDATA[Feed Eins]]></title><link>https://a.example/1</link><pubDate>Thu, 19 Nov 2026</pubDate>
<media:content url="https://a.example/1.jpg"/><description>&lt;p&gt;Hallo&lt;/p&gt;</description></item>
<item><title>Feed Zwei</title><link>https://a.example/2</link><description>&lt;img src="https://a.example/2.jpg"&gt; Text</description></item>
</channel></rss>''';
    final f = extractFeedItems(rss, Uri.parse('https://a.example/feed'));
    check(f.length == 2 && f[0].title == 'Feed Eins' && f[0].image == 'https://a.example/1.jpg' && f[1].image == 'https://a.example/2.jpg',
        'RSS mit media:content und Bild in der Beschreibung');
    final tool = WebFetchTool(fetcher: (u) async => u.path.endsWith('feed.xml') ? rss : page);
    final out = await tool.run({'url': 'https://rtb.li/p/ainews'}, ToolContext(requestNetwork: (_) async => true));
    check(out.contains('EINTRÄGE (3)') && out.contains('Bild: https://rtb.li/img/1.jpg') && out.contains('Karten'),
        'web_fetch liefert Einträge mit Bildern');
    final jsPage = '<html><head><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head><body><div id="app"></div></body></html>';
    final out2 = await WebFetchTool(fetcher: (u) async => u.path.endsWith('feed.xml') ? rss : jsPage)
        .run({'url': 'https://x.example'}, ToolContext(requestNetwork: (_) async => true));
    check(out2.contains('aus Feed') && out2.contains('Feed Zwei'), 'JavaScript-Seite → verlinkter Feed');
  });

  await group('Push-Nachrichten: Zeitangaben', () async {
    final now = DateTime(2026, 11, 19, 14, 0);
    check(parseWhen('', now) == null && parseWhen('jetzt', now) == null, 'leer/jetzt = sofort');
    check(parseWhen('in 30 Minuten', now) == DateTime(2026, 11, 19, 14, 30), 'in 30 Minuten');
    check(parseWhen('in 2 h', now) == DateTime(2026, 11, 19, 16, 0), 'in 2 h');
    check(parseWhen('15:00', now) == DateTime(2026, 11, 19, 15, 0), '15:00 heute');
    check(parseWhen('9:00 Uhr', now) == DateTime(2026, 11, 20, 9, 0), '9:00 schon vorbei → morgen');
    check(parseWhen('morgen 8:30', now) == DateTime(2026, 11, 20, 8, 30), 'morgen 8:30');
    check(parseWhen('24.12. 18:00', now) == DateTime(2026, 12, 24, 18, 0), '24.12. 18:00');
    check(parseWhen('2026-12-01 07:15', now) == DateTime(2026, 12, 1, 7, 15), 'ISO-Datum');
    var bad = false;
    try {
      parseWhen('irgendwann', now);
    } on FormatException {
      bad = true;
    }
    check(bad, 'Unsinn → Fehler');
    final sent = <(String, DateTime?)>[];
    final tool = NotifyTool((t, x, at, k, cal) async => sent.add((t, at)), clock: () => now);
    final r1 = await tool.run({'title': 'A', 'text': 'b', 'when': ''}, ToolContext());
    final r2 = await tool.run({'title': 'B', 'text': 'c', 'when': 'in 10 min'}, ToolContext());
    check(sent.length == 2 && sent[0].$2 == null && sent[1].$2 == DateTime(2026, 11, 19, 14, 10) &&
        r1.contains('gesendet') && r2.contains('14:10'), 'Tool sendet sofort und plant');
  });

  await group('Katalog: Bildmodelle und Bildverständnis', () async {
    const gb = 1 << 30;
    final mac = DeviceProfile.detect(totalMemoryOverride: 32 * gb, cpuOverride: 10, mobileOverride: false);
    final img = recommendFor(ModelKind.image, mac, freeDiskBytes: 100 * gb, availableMemory: 0);
    check(img.first.entry.id == 'sd-turbo' && img.first.suitability == Suitability.recommended, 'SD-Turbo empfohlen');
    final tiny = DeviceProfile.detect(totalMemoryOverride: 4 * gb, cpuOverride: 4, mobileOverride: true);
    final img2 = recommendFor(ModelKind.image, tiny, freeDiskBytes: 100 * gb, availableMemory: gb);
    check(img2.every((r) => r.suitability != Suitability.recommended), 'kleines Handy: Bildmodell nicht empfohlen');
    final q = modelCatalog.firstWhere((e) => e.id == 'qwen3.5-4b');
    check(q.vision && q.hfRepo == 'unsloth/Qwen3.5-4B-GGUF', 'Vision-Flag und HF-Repo');
  });

  if (modelPath == null) {
    print('\nAE_TEST_MODEL nicht gesetzt: Engine-Tests übersprungen.');
    _summary();
    return;
  }

  await group('Engine: Laden-Fehler', () async {
    var threw = false;
    try {
      await LlamaEngine.load(const EngineConfig(modelPath: '/gibt/es/nicht.gguf'));
    } on EngineException catch (e) {
      threw = true;
      print('  Meldung: $e');
    }
    check(threw, 'fehlende Datei → EngineException');
  });

  final engine = await LlamaEngine.load(EngineConfig(modelPath: modelPath, contextSize: 1024, threads: 2));

  await group('Engine: Grundfunktionen', () async {
    check(engine.info.contextSize == 1024, 'Context 1024 (${engine.info.description})');
    final prompt = await engine.formatChat(const [
      ChatMessage('system', 'Du bist hilfreich.'),
      ChatMessage('user', 'Grüß dich! Ümlaute: äöü ß 😀'),
    ]);
    check(prompt.contains('äöü ß 😀'), 'Template erhält UTF-8');
    final n = await engine.countTokens(prompt);
    check(n > 5, 'Tokens gezählt ($n)');

    final buf = StringBuffer();
    DoneEvent? done;
    await for (final ev in engine.generate(prompt, maxTokens: 24, sampling: const SamplingParams(seed: 1))) {
      if (ev is TokenEvent) buf.write(ev.text);
      if (ev is DoneEvent) done = ev;
    }
    check(done != null && done.reason == FinishReason.maxTokens, 'Generierung endet mit maxTokens (${done?.reason})');
    check(done!.stats.generatedTokens == 24, '24 Tokens erzeugt');
    print('  ${done.stats.tokensPerSecond.toStringAsFixed(1)} Tokens/s, TTFT ${done.stats.timeToFirstTokenMs.toStringAsFixed(0)} ms');

    // gleicher Prompt erneut: Präfix muss wiederverwendet werden
    await for (final ev in engine.generate(prompt, maxTokens: 4)) {
      if (ev is DoneEvent) done = ev;
    }
    check(done!.stats.reusedTokens >= n - 1, 'Präfix-Cache wiederverwendet (${done.stats.reusedTokens}/$n)');

    final mem = LlamaEngine.processMemory();
    check(mem > 0, 'Prozessspeicher lesbar (${mem ~/ (1024 * 1024)} MB)');
  });

  await group('Engine: Stop', () async {
    final prompt = await engine.formatChat(const [ChatMessage('user', 'Erzähl eine lange Geschichte.')]);
    DoneEvent? done;
    final sw = Stopwatch()..start();
    final stream = engine.generate(prompt, maxTokens: 900);
    Timer(const Duration(milliseconds: 300), engine.stop);
    await for (final ev in stream) {
      if (ev is DoneEvent) done = ev;
    }
    sw.stop();
    check(done?.reason == FinishReason.stopped, 'Grund = stopped (${done?.reason})');
    check(sw.elapsedMilliseconds < 300 + 500, 'Stop wirkt in < 0,5 s (${sw.elapsedMilliseconds - 300} ms nach Stop)');
    check(done!.stats.generatedTokens < 900, 'vor maxTokens beendet (${done.stats.generatedTokens})');
    check(!engine.isGenerating, 'Engine wieder frei');
  });

  await group('Engine: Grammatiken', () async {
    for (final subset in [builtinTools(), [CalculatorTool()], [DateTimeTool()], <AgentTool>[]]) {
      final g = AgentGrammar.build(subset);
      final err = await engine.validateGrammar(g);
      check(err == null, 'Grammatik gültig für ${subset.map((t) => t.name).join(',')} ${err ?? ''}');
    }
    check(await engine.validateGrammar(AgentGrammar.plainTextNoCjk()) == null, 'Chat-Grammatik ohne CJK gültig');
    check(await engine.validateGrammar(Workflow.jsonGrammar) == null, 'JSON-Grammatik für Prozesse gültig');
    // Zufallsmodell mit Llama-3-Vokabular erzeugt sonst häufig CJK-Zeichen
    final p = await engine.formatChat(const [ChatMessage('user', 'Schreib etwas.')]);
    final out = StringBuffer();
    await for (final ev in engine.generate(p,
        grammar: AgentGrammar.plainTextNoCjk(), maxTokens: 200, sampling: const SamplingParams(temperature: 1.5, seed: 7))) {
      if (ev is TokenEvent) out.write(ev.text);
    }
    final cjk = RegExp(r'[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uAC00-\uD7AF]');
    check(out.isNotEmpty && !cjk.hasMatch(out.toString()), 'keine CJK-Zeichen in 200 Zufallstokens (${out.length} Zeichen)');
    final bad = await engine.validateGrammar('root ::= (');
    check(bad != null, 'kaputte Grammatik erkannt');
  });

  await group('Agent: Schleife mit Zufallsmodell', () async {
    final arts = <Artifact>[];
    for (final seed in [1, 2, 3]) {
      final runner = AgentRunner(
        engine: engine,
        systemPrompt: 'Du bist ein Test-Agent.',
        tools: builtinTools(),
        maxSteps: 3,
        maxTokensPerStep: 96,
        sampling: SamplingParams(temperature: 0.9, seed: seed),
      );
      final events = <AgentEvent>[];
      await for (final ev in runner.run(
        history: const [],
        userInput: 'Was ist 17*23?',
        context: ToolContext(
            attachments: const [Attachment(name: 'a.txt', content: 'Hallo Welt')], onArtifact: arts.add),
      )) {
        events.add(ev);
      }
      final finished = events.whereType<AgentFinished>().toList();
      final calls = events.whereType<ToolCalled>().toList();
      final names = builtinTools().map((t) => t.name).toSet();
      check(finished.length == 1, 'Seed $seed: genau ein Abschluss (${finished.firstOrNull?.reason} ${finished.firstOrNull?.message ?? ''})');
      check(calls.every((c) => names.contains(c.tool)), 'Seed $seed: nur gültige Tools (${calls.map((c) => c.tool).join(', ')})');
      check(events.whereType<StepStarted>().length <= 4, 'Seed $seed: Schrittlimit eingehalten');
      check(finished.first.reason != AgentStopReason.error, 'Seed $seed: kein Fehler');
    }
  });

  await group('Agent: Chat-Modus und Context-Kürzung', () async {
    final runner = AgentRunner(engine: engine, systemPrompt: 'Test.', maxTokensPerStep: 32);
    final history = [
      for (var i = 0; i < 40; i++) ...[
        ChatMessage('user', 'Frage $i ${'lorem ipsum ' * 10}'),
        ChatMessage('assistant', 'Antwort $i ${'dolor sit ' * 10}'),
      ]
    ];
    final events = await runner
        .run(history: history, userInput: 'Und jetzt?', context: ToolContext())
        .toList();
    final fin = events.whereType<AgentFinished>().single;
    check(fin.reason == AgentStopReason.answered, 'langer Verlauf wird gekürzt statt Fehler (${fin.message ?? ''})');
    check(events.whereType<FinalAnswer>().length == 1, 'Antwort geliefert');

    final tooLong = await runner
        .run(history: const [], userInput: 'x ' * 5000, context: ToolContext())
        .toList();
    final f2 = tooLong.whereType<AgentFinished>().single;
    check(f2.reason == AgentStopReason.answered || f2.reason == AgentStopReason.error,
        'überlange Eingabe: kontrolliert (${f2.reason})');
  });

  for (final (file, name) in [('tiny_gemma4.gguf', 'Gemma 4'), ('tiny_qwen35.gguf', 'Qwen 3.5')]) {
    final path = '${File(modelPath).parent.path}/$file';
    if (!File(path).existsSync()) continue;
    await group('Template: $name', () async {
      final e2 = await LlamaEngine.load(EngineConfig(modelPath: path, contextSize: 512, threads: 2));
      final t = await e2.formatChat(const [ChatMessage('system', 'S'), ChatMessage('user', 'Hallo'), ChatMessage('assistant', 'Hi'), ChatMessage('user', 'Und?')]);
      print('  ${t.replaceAll('\n', r'\n')}');
      if (name == 'Gemma 4') {
        check(t == '<|turn>system\nS<turn|>\n<|turn>user\nHallo<turn|>\n<|turn>model\nHi<turn|>\n<|turn>user\nUnd?<turn|>\n<|turn>model\n<|channel>thought\n<channel|>',
            'Gemma-4-Format mit abgeschaltetem Denkmodus');
      } else {
        check(t.contains('<|im_start|>assistant\n') && t.endsWith('<think>\n\n</think>\n\n'), 'ChatML + leerer Denkblock');
      }
      await e2.dispose();
    });
  }

  await group('Schnellstart: Vorberechnung und KV-Zustand auf Platte', () async {
    final sys = 'Du bist ein Testassistent. ' * 40;
    final p1 = await engine.formatChat([ChatMessage('system', sys), const ChatMessage('user', 'Hallo')]);
    final ms = await engine.prefill(await engine.formatChat([ChatMessage('system', sys)]));
    check(ms >= 0, 'Vorberechnung ($ms ms)');
    final tmp = File('${Directory.systemTemp.path}/ae_state_test.bin');
    final saved = await engine.saveState(tmp.path);
    check(saved > 50 && tmp.existsSync(), 'Zustand gespeichert ($saved Tokens, ${tmp.lengthSync() ~/ 1024} KB)');
    final e2 = await LlamaEngine.load(EngineConfig(modelPath: modelPath, contextSize: 2048, threads: 2));
    final loaded = await e2.loadState(tmp.path);
    check(loaded == saved, 'Zustand in neue Engine geladen');
    GenerationStats? st;
    await for (final ev in e2.generate(p1, maxTokens: 4)) {
      if (ev is DoneEvent) st = ev.stats;
    }
    check(st != null && st.reusedTokens >= saved - 8, 'Prompt nutzt geladenen Zustand (${st?.reusedTokens} wiederverwendet)');
    check(await e2.loadState('/gibt/es/nicht.bin') == 0, 'fehlende Datei → 0');
    await e2.dispose();
    tmp.deleteSync();
  });

  await engine.dispose();
  _summary();
}

void _summary() {
  print('\n$_passed bestanden, $_failed fehlgeschlagen');
  exit(_failed == 0 ? 0 : 1);
}

/// Liefert vorgegebene Antworten, um die Agenten-Schleife deterministisch zu testen.
class ScriptedBackend implements AgentBackend {
  ScriptedBackend(this.outputs, {this.contextSize = 4096});
  final List<String> outputs;
  final prompts = <String>[];
  final grammars = <String?>[];
  @override
  final int contextSize;
  var _i = 0;

  @override
  Future<String> formatChat(List<ChatMessage> messages, {bool addAssistant = true}) async =>
      messages.map((m) => '<${m.role}>${m.content}').join('\n');
  @override
  Future<int> countTokens(String text) async => text.length ~/ 4;
  @override
  Stream<GenerationEvent> generate(String prompt,
      {String? grammar, SamplingParams sampling = const SamplingParams(), int maxTokens = 1024}) async* {
    prompts.add(prompt);
    grammars.add(grammar);
    final out = _i < outputs.length ? outputs[_i++] : '{"thought": "", "final_answer": "Ende"}';
    for (var k = 0; k < out.length; k += 7) {
      yield TokenEvent(out.substring(k, k + 7 > out.length ? out.length : k + 7));
    }
    yield DoneEvent(FinishReason.done, GenerationStats.fromList([10, 5, 20, 100, 30, contextSize.toDouble(), 0, 5]));
  }
  @override
  void stop() {}
}

class _MapSource implements SyncSource {
  _MapSource(Map<String, String> init) : data = Map.of(init);
  final Map<String, String> data;
  @override
  Future<Map<String, String>> exportAll() async => Map.of(data);
  @override
  Future<void> apply(String key, String? json) async {
    if (json == null) {
      data.remove(key);
    } else {
      data[key] = json;
    }
  }
}

class _FakeBrowser implements BrowserDriver {
  final opened = <String>[];
  final scripts = <String>[];
  bool shown = false, allow = true, captcha = false;
  int settled = 0, confirms = 0, handOvers = 0;
  @override
  Future<void> show() async => shown = true;
  @override
  Future<void> open(Uri url) async => opened.add(url.toString());
  @override
  Future<void> settle() async => settled++;
  @override
  Future<void> back() async {}
  @override
  Future<bool> confirm(String title, String detail) async {
    confirms++;
    return allow;
  }

  @override
  Future<bool> handOver(String message) async {
    handOvers++;
    captcha = false;
    return true;
  }

  @override
  Future<String> eval(String js) async {
    scripts.add(js);
    if (!js.contains('data-jid]')) return jsonEncode('{"ok":true}'); // Android: doppelt kodiert
    return jsonEncode({
      'url': 'https://shop.example/', 'title': 'Shop', 'captcha': captcha, 'more': true, 'text': 'Willkommen',
      'els': [
        {'id': 1, 'kind': 'input', 'label': 'Suche', 'type': 'search', 'search': 1},
        {'id': 2, 'kind': 'input', 'label': 'Passwort', 'type': 'password', 'secret': 1},
        {'id': 3, 'kind': 'button', 'label': 'Jetzt kaufen'},
      ],
      'cards': [
        {'title': 'Wesco Brotkasten Grandy', 'link': 'https://shop.example/p/1', 'image': 'https://shop.example/1.jpg', 'price': '€ 59,90'},
        {'title': 'App Store', 'link': 'https://apps.apple.com/x', 'image': 'https://shop.example/a.png', 'price': ''},
      ],
    });
  }
}

class _FakeDevice implements DeviceActions {
  @override
  Future<String> calendarInfo() async => 'Gelesene Kalender: Privat (a@b.at: 0 Termine)';
  final log = <String>[];
  bool allow = true;
  String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  @override
  String get countryCode => '43';
  @override
  Future<List<ContactInfo>> contacts(String q) async => [
        ContactInfo('Anna Berger', ['0664 1234567'], ['anna@example.com']),
        ContactInfo('Max Muster', ['01 555'], []),
        ContactInfo('Max Mayer', ['0699 1'], []),
      ].where((c) => c.name.toLowerCase().contains(q.toLowerCase())).toList();
  @override
  Future<void> composeEmail(String to, String subject, String body) async => log.add('mail:$to|$subject|$body');
  @override
  Future<void> whatsapp(String phone, String text) async => log.add('wa:$phone|$text');
  @override
  Future<void> dial(String number) async => log.add('dial:$number');
  @override
  Future<void> calendarInsert(CalendarEvent e) async => log.add('cal:${e.title}|${_d(e.begin)}|${_d(e.end)}|${e.allDay}');
  @override
  Future<List<CalendarEvent>> calendarList(DateTime from, DateTime to) async {
    log.add('list:${_d(from)}-${_d(to)}');
    return [CalendarEvent('Team-Meeting', DateTime(2026, 11, 20, 9), DateTime(2026, 11, 20, 10), location: 'Büro')];
  }
  @override
  Future<List<FileHit>> fileSearch(String q, String ext) async => [];
  @override
  Future<String> fileRename(String path, String n) async {
    log.add('rename:$path>$n');
    return n;
  }
  @override
  Future<String> fileMove(String path, String folder) async {
    log.add('move:$path>$folder');
    return folder;
  }
  @override
  Future<bool> confirm(String title, String detail) async => allow;
}

class _SlowTool extends AgentTool {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  String get name => 'slow';
  @override
  String get title => 'Langsam';
  @override
  String get description => 'wartet';
  @override
  List<ToolParam> get params => const [ToolParam('q', ParamType.string, 'Suche')];
  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return 'Hotel A 120 €, Hotel B 140 €, Hotel C 210 €';
  }
}

/// Gibt Tokens langsam aus und lässt sich per stop() abbrechen.
class _SlowBackend implements AgentBackend {
  _SlowBackend(this.outputs);
  final List<String> outputs;
  final prompts = <String>[];
  final firstToken = Completer<void>();
  var stops = 0;
  var _stop = false;
  var _i = 0;
  @override
  int get contextSize => 4096;
  @override
  Future<String> formatChat(List<ChatMessage> messages, {bool addAssistant = true}) async =>
      messages.map((m) => '<${m.role}>${m.content}').join('\n');
  @override
  Future<int> countTokens(String text) async => text.length ~/ 4;
  @override
  Stream<GenerationEvent> generate(String prompt,
      {String? grammar, SamplingParams sampling = const SamplingParams(), int maxTokens = 1024}) async* {
    prompts.add(prompt);
    _stop = false;
    final out = outputs[_i++ % outputs.length];
    for (final w in out.split(' ')) {
      if (_stop) {
        yield DoneEvent(FinishReason.stopped, GenerationStats.fromList([1, 1, 1, 1, 1, 4096, 0, 1]));
        return;
      }
      yield TokenEvent('$w ');
      if (!firstToken.isCompleted) firstToken.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    yield DoneEvent(FinishReason.done, GenerationStats.fromList([1, 1, 1, 1, 1, 4096, 0, 1]));
  }

  @override
  void stop() {
    stops++;
    _stop = true;
  }
}
