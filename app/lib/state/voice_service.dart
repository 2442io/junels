// Sprache: Mikrofon als PCM-Stream (für Diktat und Gesprächsmodus),
// Whisper-Erkennung und Sprachausgabe mit Warteschlange
// (Piper über sherpa-onnx, Systemstimme als Rückfallebene).

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:agent_engine/agent_engine.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

enum VoicePhase { idle, recording, transcribing }

// ===========================================================================
// Mikrofon
// ===========================================================================

/// Liefert 16-kHz-Mono-Frames (float) vom Mikrofon.
class MicStream {
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _sub;
  int _rate = 16000;
  bool get running => _sub != null;

  final level = ValueNotifier<double>(0);

  Future<bool> hasPermission() async => (_rec ??= AudioRecorder()).hasPermission();

  /// [echoCancel]: Echo-Unterdrückung (wichtig, wenn der Agent gleichzeitig spricht).
  Future<void> start(void Function(Float32List frame16k) onFrame, {bool echoCancel = false}) async {
    await stop();
    final r = _rec ??= AudioRecorder();
    if (!await r.hasPermission()) {
      throw Exception('Kein Zugriff auf das Mikrofon. Bitte in den Systemeinstellungen erlauben.');
    }
    Stream<Uint8List>? stream;
    Object? lastError;
    // Manche Geräte (v. a. macOS) lehnen 16 kHz oder Echo-Unterdrückung ab → Varianten probieren
    final variants = <(int, bool)>[
      if (echoCancel) (16000, true),
      if (echoCancel) (48000, true),
      (16000, false),
      (48000, false),
      (44100, false),
    ];
    for (final (rate, aec) in variants) {
      try {
        stream = await r.startStream(RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: rate,
          numChannels: 1,
          echoCancel: aec,
          noiseSuppress: aec,
        ));
        _rate = rate;
        break;
      } catch (e) {
        lastError = e;
        try {
          await r.cancel();
        } catch (_) {}
      }
    }
    if (stream == null) throw Exception('Aufnahme konnte nicht gestartet werden: $lastError');
    _sub = stream.listen((chunk) {
      final bd = ByteData.sublistView(chunk);
      final n = chunk.length ~/ 2;
      final f = Float32List(n);
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
        f[i] = v;
        sum += v * v;
      }
      if (n > 0) {
        final db = 20 * math.log(math.sqrt(sum / n) + 1e-9) / math.ln10;
        level.value = ((db + 60) / 60).clamp(0.0, 1.0);
      }
      onFrame(resampleLinear(f, _rate, 16000));
    });
  }

  Future<void> stop() async {
    final s = _sub;
    _sub = null;
    level.value = 0;
    try {
      await _rec?.stop();
    } catch (_) {}
    await s?.cancel();
  }

  Future<void> dispose() async {
    await stop();
    await _rec?.dispose();
  }
}

// ===========================================================================
// Sprachausgabe mit Warteschlange
// ===========================================================================

class SpeechOutput {
  SpeechOutput(this.tempDir);
  final Directory tempDir;

  /// Gerade gesprochen (für Anzeige/Unterbrechen).
  final speaking = ValueNotifier<bool>(false);
  final lastError = ValueNotifier<String?>(null);

  /// Welche Stimme zuletzt verwendet wurde ("Piper …" oder "Systemstimme").
  String engineLabel = '';

  _TtsWorker? _piper;
  String? _piperDir;
  FlutterTts? _system;
  final AudioPlayer _player = AudioPlayer();

  final List<_QueueItem> _queue = [];
  bool _finished = true;
  int _generation = 0;
  Completer<void>? _drained;
  Completer<void>? _playDone;
  bool _loopRunning = false;

  String? voiceDir; // Piper-Ordner oder null = Systemstimme
  String language = 'de';
  double speed = 1.0;

  /// Startet eine neue Ausgabe; danach [add] und am Ende [finish].
  void begin() {
    stop();
    _finished = false;
    _drained = Completer<void>();
  }

  void add(String sentence) {
    if (sentence.trim().isEmpty) return;
    _queue.add(_QueueItem(sentence));
    _kick();
  }

  void finish() {
    _finished = true;
    _kick();
  }

  /// Wartet, bis alles gesprochen (oder abgebrochen) ist.
  Future<void> get done => _drained?.future ?? Future.value();

  /// Ganzen Text sprechen (Vorlesen-Taste).
  Future<void> speakAll(String text) async {
    begin();
    for (final s in splitForSpeech(cleanForSpeech(text))) {
      add(s);
    }
    finish();
    await done;
  }

  void stop() {
    _generation++;
    _queue.clear();
    _finished = true;
    final p = _playDone;
    if (p != null && !p.isCompleted) p.complete();
    try {
      _player.stop();
    } catch (_) {}
    try {
      _system?.stop();
    } catch (_) {}
    speaking.value = false;
    final d = _drained;
    if (d != null && !d.isCompleted) d.complete();
  }

  void _kick() {
    if (_loopRunning) return;
    _loopRunning = true;
    final gen = _generation;
    unawaited(_loop(gen).whenComplete(() {
      _loopRunning = false;
      // Falls während des Endes neue Sätze kamen
      if (_queue.isNotEmpty && gen != _generation) _kick();
    }));
  }

  Future<void> _loop(int gen) async {
    while (gen == _generation) {
      if (_queue.isEmpty) {
        if (_finished) break;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        continue;
      }
      final item = _queue.removeAt(0);
      final clipF = item.clip ??= _synth(item.text);
      // nächsten Satz schon erzeugen, während dieser spielt
      if (_queue.isNotEmpty) _queue.first.clip ??= _synth(_queue.first.text);
      final clip = await clipF;
      if (gen != _generation) break;
      speaking.value = true;
      if (clip == null) {
        await _speakSystem(item.text); // Piper nicht verfügbar → Systemstimme
      } else {
        await _play(clip);
        unawaited(File(clip.path!).delete().then((_) {}, onError: (_) {}));
      }
    }
    if (gen == _generation) {
      speaking.value = false;
      final d = _drained;
      if (d != null && !d.isCompleted) d.complete();
    }
  }

  Future<_Clip?> _synth(String text) async {
    final dir = voiceDir;
    if (dir == null) return null;
    try {
      if (_piper == null || _piperDir != dir) {
        await _piper?.dispose();
        _piper = null;
        _piper = await _TtsWorker.start(dir).timeout(const Duration(seconds: 60),
            onTimeout: () => throw Exception('Piper-Stimme lädt nicht (Zeitüberschreitung)'));
        _piperDir = dir;
      }
      final path = '${tempDir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.wav';
      final c = await _piper!.synth(text, path, speed).timeout(const Duration(seconds: 45),
          onTimeout: () => throw Exception('Piper antwortet nicht (Zeitüberschreitung)'));
      engineLabel = 'Piper';
      return c;
    } catch (e) {
      // Piper defekt → für diese Sitzung auf Systemstimme umschalten
      lastError.value = 'Piper: $e – nutze Systemstimme.';
      voiceDir = null;
      return null;
    }
  }

  Future<void> _play(_Clip clip) async {
    final done = _playDone = Completer<void>();
    final sub = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      await _player.play(DeviceFileSource(clip.path!));
      // Sicherheitsnetz, falls das Ende-Ereignis ausbleibt
      final ms = (clip.seconds * 1000).round() + 1500;
      await done.future.timeout(Duration(milliseconds: ms), onTimeout: () {});
    } catch (e) {
      lastError.value = 'Wiedergabe: $e';
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _speakSystem(String text) async {
    try {
      final t = _system ??= FlutterTts();
      await t.awaitSpeakCompletion(true);
      await t.setLanguage(language == 'en' ? 'en-US' : 'de-DE');
      await t.setSpeechRate(Platform.isAndroid ? 0.5 : 0.5 * speed);
      engineLabel = 'Systemstimme';
      await t.speak(text).timeout(Duration(seconds: 10 + text.length ~/ 8), onTimeout: () => null);
    } catch (e) {
      lastError.value = 'Systemstimme: $e';
    }
  }

  /// Test für den Systemcheck: erzeugt einen Satz und meldet Details.
  Future<String> diagnose(String dir) async {
    final sw = Stopwatch()..start();
    final w = await _TtsWorker.start(dir).timeout(const Duration(seconds: 60));
    final load = sw.elapsedMilliseconds;
    final path = '${tempDir.path}/diag.wav';
    final c = await w.synth('Hallo! So klinge ich.', path, 1.0).timeout(const Duration(seconds: 45));
    await w.dispose();
    if (c.path == null) return 'Piper hat kein Audio erzeugt (Ladezeit $load ms).';
    await _play(c);
    return 'Piper OK: ${c.seconds.toStringAsFixed(1)} s Audio, ${c.sampleRate} Hz, '
        'geladen in $load ms, erzeugt in ${sw.elapsedMilliseconds - load} ms.';
  }

  Future<void> dispose() async {
    stop();
    await _piper?.dispose();
    await _player.dispose();
  }
}

class _QueueItem {
  _QueueItem(this.text);
  final String text;
  Future<_Clip?>? clip;
}

class _Clip {
  _Clip(this.path, this.seconds, this.sampleRate);
  final String? path;
  final double seconds;
  final int sampleRate;
}

// ===========================================================================
// Fassade für die App (Diktat-Taste + Vorlesen)
// ===========================================================================

class VoiceService {
  VoiceService(this.tempDir) : output = SpeechOutput(tempDir);

  final Directory tempDir;
  final SpeechOutput output;
  final MicStream mic = MicStream();

  final phase = ValueNotifier<VoicePhase>(VoicePhase.idle);
  final recordSeconds = ValueNotifier<int>(0);

  /// Nachricht, die gerade vorgelesen wird (für die Taste).
  final speakingKey = ValueNotifier<Object?>(null);

  ValueNotifier<double> get level => mic.level;

  final List<Float32List> _dictation = [];
  Timer? _timer;

  SttEngine? _stt;
  String? _sttPath;

  Future<SttEngine> stt(String modelPath) async {
    if (_stt != null && _sttPath == modelPath) return _stt!;
    await _stt?.dispose();
    _stt = null;
    _stt = await SttEngine.load(modelPath);
    _sttPath = modelPath;
    return _stt!;
  }

  // ------------------------------------------------------------ Diktat-Taste

  Future<void> startRecording() async {
    if (phase.value != VoicePhase.idle) return;
    await stopSpeaking();
    _dictation.clear();
    await mic.start(_dictation.add);
    recordSeconds.value = 0;
    phase.value = VoicePhase.recording;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      recordSeconds.value = t.tick;
      if (t.tick >= 120) unawaited(mic.stop());
    });
  }

  Future<void> cancelRecording() async {
    _timer?.cancel();
    await mic.stop();
    _dictation.clear();
    phase.value = VoicePhase.idle;
  }

  Future<Transcript> stopAndTranscribe({
    required String modelPath,
    required String language,
    required int threads,
  }) async {
    _timer?.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await mic.stop();
    phase.value = VoicePhase.transcribing;
    try {
      final total = _dictation.fold<int>(0, (a, b) => a + b.length);
      final pcm = Float32List(total);
      var o = 0;
      for (final f in _dictation) {
        pcm.setAll(o, f);
        o += f.length;
      }
      _dictation.clear();
      if (pcm.length < 16000 * 0.4) throw Exception('Aufnahme zu kurz');
      return await (await stt(modelPath)).transcribe(pcm, language: language, threads: threads);
    } finally {
      phase.value = VoicePhase.idle;
    }
  }

  // ---------------------------------------------------------------- Vorlesen

  Future<void> speak(String text, {String? voiceDir, Object? key, String language = 'de'}) async {
    await stopSpeaking();
    speakingKey.value = key ?? text.hashCode;
    output
      ..voiceDir = voiceDir
      ..language = language;
    try {
      await output.speakAll(text);
    } finally {
      if (speakingKey.value == (key ?? text.hashCode)) speakingKey.value = null;
    }
  }

  Future<void> stopSpeaking() async {
    speakingKey.value = null;
    output.stop();
  }

  Future<void> dispose() async {
    await cancelRecording();
    await output.dispose();
    await mic.dispose();
    await _stt?.dispose();
  }
}

// ===========================================================================
// Piper-Isolate (sherpa-onnx)
// ===========================================================================

class _TtsWorker {
  _TtsWorker(this._isolate, this._send, this._responses);
  final Isolate _isolate;
  final SendPort _send;
  final Stream<dynamic> _responses;
  int _id = 1;

  static Future<_TtsWorker> start(String voiceDir) async {
    final rp = ReceivePort();
    final errors = ReceivePort();
    final iso = await Isolate.spawn(_ttsMain, rp.sendPort, debugName: 'piper', onError: errors.sendPort);
    final responses = rp.asBroadcastStream();
    final crash = Completer<Map>();
    errors.listen((e) {
      if (!crash.isCompleted) crash.complete({'id': 0, 'ok': false, 'error': 'Absturz im Sprach-Prozess: $e'});
    });
    final send = await Future.any([responses.first, crash.future.then((m) => throw Exception(m['error']))]) as SendPort;
    send.send({'cmd': 'load', 'id': 0, 'dir': voiceDir});
    final r = await Future.any([
      responses.firstWhere((m) => m is Map && m['id'] == 0).then((m) => m as Map),
      crash.future,
    ]);
    if (r['ok'] != true) {
      iso.kill(priority: Isolate.immediate);
      throw Exception(r['error'] ?? 'Stimme konnte nicht geladen werden');
    }
    return _TtsWorker(iso, send, responses);
  }

  Future<_Clip> synth(String text, String outPath, double speed) async {
    final id = _id++;
    final f = _responses.firstWhere((m) => m is Map && m['id'] == id);
    _send.send({'cmd': 'synth', 'id': id, 'text': text, 'out': outPath, 'speed': speed});
    final r = await f as Map;
    if (r['ok'] != true) throw Exception(r['error'] ?? 'Sprachausgabe fehlgeschlagen');
    if (r['path'] == null) throw Exception('Piper hat für „$text“ kein Audio erzeugt');
    return _Clip(r['path'] as String, (r['seconds'] as num).toDouble(), r['rate'] as int);
  }

  Future<void> dispose() async {
    _send.send({'cmd': 'dispose', 'id': -1});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

void _ttsMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  sherpa.OfflineTts? tts;

  inbox.listen((dynamic msg) {
    final m = msg as Map;
    final id = m['id'];
    try {
      switch (m['cmd']) {
        case 'load':
          sherpa.initBindings();
          final dir = Directory(m['dir'] as String);
          if (!dir.existsSync()) {
            out.send({'id': id, 'ok': false, 'error': 'Stimmen-Ordner fehlt: ${dir.path}'});
            return;
          }
          // Archiv kann eine zusätzliche Ordnerebene haben → rekursiv suchen
          final files = dir.listSync(recursive: true).whereType<File>().toList();
          final model = files.where((f) => f.path.endsWith('.onnx')).firstOrNull;
          final tokens = files.where((f) => f.path.endsWith('tokens.txt')).firstOrNull;
          final espeak = dir
              .listSync(recursive: true)
              .whereType<Directory>()
              .where((d) => d.path.endsWith('espeak-ng-data'))
              .firstOrNull;
          if (model == null || tokens == null || espeak == null) {
            out.send({
              'id': id,
              'ok': false,
              'error': 'Stimme unvollständig (onnx: ${model != null}, tokens: ${tokens != null}, '
                  'espeak-ng-data: ${espeak != null})',
            });
            return;
          }
          tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
            model: sherpa.OfflineTtsModelConfig(
              vits: sherpa.OfflineTtsVitsModelConfig(
                model: model.path,
                tokens: tokens.path,
                dataDir: espeak.path,
              ),
              numThreads: 2,
            ),
          ));
          out.send({'id': id, 'ok': true});
        case 'synth':
          final audio = tts!.generate(text: m['text'] as String, speed: (m['speed'] as num).toDouble());
          if (audio.samples.isEmpty || audio.sampleRate <= 0) {
            out.send({'id': id, 'ok': true, 'path': null});
            return;
          }
          final path = m['out'] as String;
          File(path).writeAsBytesSync(encodeWav16(audio.samples, audio.sampleRate));
          out.send({
            'id': id,
            'ok': true,
            'path': path,
            'seconds': audio.samples.length / audio.sampleRate,
            'rate': audio.sampleRate,
          });
        case 'dispose':
          tts?.free();
          tts = null;
          inbox.close();
      }
    } catch (e) {
      out.send({'id': id, 'ok': false, 'error': e.toString()});
    }
  });
}
