// Tests mit echten Medien-Modellen (im CI): Bildverständnis und Bildgenerierung.
//   AE_LIB_PATH=… AE_TEST_VISION_MODEL=… AE_TEST_MMPROJ=… AE_TEST_IMAGE=… AE_TEST_SD_MODEL=… dart run test/media_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';

var _passed = 0;
var _failed = 0;

void check(bool ok, String name) {
  if (ok) {
    _passed++;
    print('  ok   $name');
  } else {
    _failed++;
    print('  FAIL $name');
  }
}

Future<void> group(String name, Future<void> Function() body) async {
  print(name);
  try {
    await body();
  } catch (e, st) {
    _failed++;
    print('  FAIL Ausnahme: $e\n$st');
  }
}

Future<void> main() async {
  final outDir = Directory(Platform.environment['AE_TEST_OUT'] ?? 'testout')..createSync(recursive: true);
  // Bildverständnis: nur mit echtem Vision-Modell (z. B. im CI SmolVLM-256M)
  final vModel = Platform.environment['AE_TEST_VISION_MODEL'] ?? '';
  final vProj = Platform.environment['AE_TEST_MMPROJ'] ?? '';
  final vImage = Platform.environment['AE_TEST_IMAGE'] ?? '';
  if (vModel.isNotEmpty && File(vModel).existsSync()) {
    await group('Bildverständnis (mtmd)', () async {
      final ve = await LlamaEngine.load(EngineConfig(modelPath: vModel, contextSize: 4096, threads: 2));
      var threw = false;
      try {
        await ve.loadVision('/gibt/es/nicht.gguf');
      } on EngineException {
        threw = true;
      }
      check(threw && !ve.visionReady, 'fehlende Projektor-Datei → Fehler');
      await ve.loadVision(vProj);
      check(ve.visionReady, 'Projektor geladen');
      final prompt = await ve.formatChat([ChatMessage('user', '${LlamaEngine.imageMarker}\nDescribe this image in one sentence.')]);
      final out = StringBuffer();
      DoneEvent? done;
      await for (final ev in ve.generateWithImages(prompt, [vImage], maxTokens: 60)) {
        if (ev is TokenEvent) out.write(ev.text);
        if (ev is DoneEvent) done = ev;
      }
      print('  Antwort: ${out.toString().trim()}');
      check(done != null && done.error == null && out.toString().trim().length > 5, 'Bild wird beschrieben');
      // danach funktioniert normaler Text weiter (Cache wurde verworfen)
      final p2 = await ve.formatChat(const [ChatMessage('user', 'Say hello.')]);
      final out2 = StringBuffer();
      await for (final ev in ve.generate(p2, maxTokens: 10)) {
        if (ev is TokenEvent) out2.write(ev.text);
      }
      check(out2.isNotEmpty, 'Textgenerierung nach Bild funktioniert');
      var badImage = false;
      await for (final ev in ve.generateWithImages(prompt, ['/gibt/es/nicht.jpg'])) {
        if (ev is DoneEvent && ev.error != null) badImage = true;
      }
      check(badImage, 'unlesbares Bild → Fehlermeldung');
      await ve.dispose();
    });
  }


  final sdModel = Platform.environment['AE_TEST_SD_MODEL'] ?? '';
  if (sdModel.isNotEmpty && File(sdModel).existsSync()) {
    await group('Bildgenerierung (stable-diffusion.cpp)', () async {
      check(ImageEngine.available, 'Bildgenerierung eingebaut');
      var threw = false;
      try {
        await ImageEngine.load('/gibt/es/nicht.gguf');
      } on ImageGenException catch (e) {
        threw = true;
        print('  Meldung: $e');
      }
      check(threw, 'fehlendes Modell → Fehler');
      final sw = Stopwatch()..start();
      final eng = await ImageEngine.load(sdModel, threads: 4);
      print('  geladen in ${sw.elapsedMilliseconds} ms');
      sw.reset();
      var progressCalls = 0;
      final img = await eng.generate(const ImageRequest('a red apple on a wooden table, photo', width: 256, height: 256, steps: 1, seed: 42),
          onProgress: (s, t) => progressCalls++);
      print('  erzeugt in ${sw.elapsedMilliseconds} ms, ${img.width}x${img.height}');
      check(img.width == 256 && img.height == 256 && img.rgb.length == 256 * 256 * 3, 'Bild 256×256 erzeugt');
      var sum = 0, sumR = 0;
      for (var i = 0; i < img.rgb.length; i += 3) {
        sum += img.rgb[i] + img.rgb[i + 1] + img.rgb[i + 2];
        sumR += img.rgb[i];
      }
      check(sum > 0 && sum < 255 * img.rgb.length, 'Bild ist nicht leer (Ø ${(sum / img.rgb.length).round()})');
      final rgba = Uint8List(img.width * img.height * 4);
      for (var i = 0; i < img.width * img.height; i++) {
        rgba[i * 4] = img.rgb[i * 3];
        rgba[i * 4 + 1] = img.rgb[i * 3 + 1];
        rgba[i * 4 + 2] = img.rgb[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
      }
      File('${outDir.path}/apfel.png').writeAsBytesSync(encodePngRgba(img.width, img.height, rgba));
      print('  Rotanteil ${(sumR * 3 / sum * 100).round()} % (Apfel sollte rot sein)');
      // Abbruch
      final f = eng.generate(const ImageRequest('a mountain landscape', width: 256, height: 256, steps: 8));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      eng.cancel();
      var cancelled = false;
      try {
        await f;
      } on ImageGenException catch (e) {
        cancelled = e.message.contains('abgebrochen');
      }
      check(cancelled, 'Abbrechen funktioniert');
      await eng.dispose();
    });
  }

  print('\n$_passed bestanden, $_failed fehlgeschlagen');
  exit(_failed == 0 ? 0 : 1);
}
