// Ohne package:test lauffähige Tests (nur Dart SDK nötig).
//
//   AE_LIB_PATH=/pfad/libagent_engine.so AE_TEST_MODEL=/pfad/modell.gguf \
//     dart run test/engine_test.dart
//
// Ohne AE_TEST_MODEL laufen nur die Tests ohne Modell.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';

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
        recommendFor(k, d, freeDiskBytes: free).first.entry.id;
    check(best(ModelKind.llm, s) == 'qwen2.5-1.5b', 'S → Qwen 2.5 1.5B');
    check(best(ModelKind.llm, m) == 'qwen3-4b-2507', 'M → Qwen3 4B');
    check(best(ModelKind.llm, l) == 'qwen2.5-7b', 'L → Qwen 2.5 7B');
    check(best(ModelKind.stt, s) == 'whisper-base', 'S → Whisper base');
    check(best(ModelKind.stt, m) == 'whisper-turbo-q5', 'M → Whisper turbo q5');
    // Rechner (Linux/macOS) gilt als Desktop → volle Präzision
    check(best(ModelKind.stt, l) == 'whisper-turbo', 'L Desktop → Whisper turbo voll');
    check(best(ModelKind.tts, m) == 'piper-de-thorsten', 'Stimme → Thorsten');
    final noSpace = recommendFor(ModelKind.llm, l, freeDiskBytes: 1 * gb);
    check(noSpace.firstWhere((r) => r.entry.id == 'qwen2.5-7b').suitability == Suitability.noSpace,
        'zu wenig Speicher erkannt');
    final tooBig = recommendFor(ModelKind.llm, s, freeDiskBytes: 100 * gb);
    check(tooBig.firstWhere((r) => r.entry.id == 'qwen2.5-7b').suitability == Suitability.tooBig,
        '7B auf S als zu groß markiert');
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
