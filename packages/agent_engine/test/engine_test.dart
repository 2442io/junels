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
        recommendFor(k, d, freeDiskBytes: free, availableMemory: 0).first.entry.id;
    final xl = DeviceProfile.detect(totalMemoryOverride: 128 * gb, cpuOverride: 16);
    check(best(ModelKind.llm, s) == 'qwen3.5-2b', 'S → Qwen 3.5 2B');
    check(best(ModelKind.llm, m) == 'qwen3.5-4b', 'M → Qwen 3.5 4B');
    check(best(ModelKind.llm, l) == 'qwen3.5-9b', 'L → Qwen 3.5 9B');
    check(xl.deviceClass == DeviceClass.xl && xl.maxContext == 16384, 'XL bei 128 GB, 16K Context');
    check(best(ModelKind.llm, xl) == 'gemma-4-26b-a4b', 'XL → Gemma 4 26B A4B');
    check(best(ModelKind.stt, xl) == 'whisper-turbo', 'XL → Whisper turbo voll');
    check(best(ModelKind.stt, s) == 'whisper-base', 'S → Whisper base');
    check(best(ModelKind.stt, m) == 'whisper-turbo-q5', 'M → Whisper turbo q5');
    // Rechner (Linux/macOS) gilt als Desktop → volle Präzision
    check(best(ModelKind.stt, l) == 'whisper-turbo', 'L Desktop → Whisper turbo voll');
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
    final r = await RememberTool((f) async => saved.add(f)).run({'fact': 'Nutzer heißt Christoph'}, ToolContext());
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
    final tool = NotifyTool((t, x, at) async => sent.add((t, at)), clock: () => now);
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
