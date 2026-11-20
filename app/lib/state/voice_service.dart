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
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

enum VoicePhase { idle, recording, transcribing }

/// Protokolldatei der App (wird beim Start gesetzt).
File? voiceLogFile;

/// Neue Protokollzeile (für die Protokoll-Seite).
final logTick = ValueNotifier<int>(0);

/// Eintrag ins App-Protokoll. [area] z. B. "Modell", "Agent", "Sprache", "Sync".
void appLog(String area, String msg, {bool error = false}) {
  final ts = DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
  final line = '$ts  ${error ? 'FEHLER' : 'info  '}  [$area] ${msg.replaceAll('\n', ' ⏎ ')}\n';
  debugPrint(line);
  final f = voiceLogFile;
  if (f == null) return;
  try {
    if (f.existsSync() && f.lengthSync() > 400000) {
      // ältere Hälfte verwerfen
      final all = f.readAsStringSync();
      f.writeAsStringSync(all.substring(all.length ~/ 2));
    }
    f.writeAsStringSync(line, mode: FileMode.append, flush: true);
    logTick.value++;
  } catch (_) {}
}

void voiceLog(String msg) =>
    appLog('Sprache', msg, error: RegExp(r'fehl|Fehler|nicht verfügbar|Exception', caseSensitive: false).hasMatch(msg));

// ===========================================================================
// Mikrofon
// ===========================================================================

/// Liefert 16-kHz-Mono-Frames (float) vom Mikrofon.
class MicStream {
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _sub;
  int _rate = 16000;
  bool get running => _sub != null;

  /// Zeitpunkt des letzten Audio-Blocks (zum Erkennen eines hängenden Mikrofons).
  DateTime lastFrameAt = DateTime.now();

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
    lastFrameAt = DateTime.now();
    _sub = stream.listen((chunk) {
      lastFrameAt = DateTime.now();
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
        final ok = await _play(clip);
        if (!ok && gen == _generation) await _speakSystem(item.text);
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
    } catch (e, st) {
      // Piper defekt → für diese Sitzung auf Systemstimme umschalten
      voiceLog('Piper-Fehler ($dir): $e\n$st');
      lastError.value = 'Piper: $e – nutze Systemstimme.';
      voiceDir = null;
      return null;
    }
  }

  Future<bool> _play(_Clip clip) async {
    final done = _playDone = Completer<void>();
    final sub = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      await _player.play(DeviceFileSource(clip.path!));
      // Sicherheitsnetz, falls das Ende-Ereignis ausbleibt
      final ms = (clip.seconds * 1000).round() + 1500;
      await done.future.timeout(Duration(milliseconds: ms), onTimeout: () {});
      return true;
    } catch (e, st) {
      voiceLog('Wiedergabe-Fehler (${clip.path}): $e\n$st');
      lastError.value = 'Wiedergabe: $e';
      return false;
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
      voiceLog('Systemstimme-Fehler: $e');
      lastError.value = 'Systemstimme: $e';
    }
  }

  /// Test für den Systemcheck: erzeugt einen Satz, spielt ihn ab und meldet Details.
  /// Wirft nie – liefert (ok, Bericht).
  Future<(bool, String)> diagnose(String dir) async {
    final sw = Stopwatch()..start();
    final report = StringBuffer('Stimmen-Ordner: $dir\n');
    try {
      final files = Directory(dir).listSync(recursive: true).whereType<File>().map((f) => f.path.substring(dir.length)).toList();
      report.writeln('Dateien: ${files.length} (onnx: ${files.where((f) => f.endsWith('.onnx')).join(', ')})');
    } catch (e) {
      report.writeln('Ordner nicht lesbar: $e');
    }
    _TtsWorker? w;
    try {
      w = await _TtsWorker.start(dir).timeout(const Duration(seconds: 60),
          onTimeout: () => throw Exception('Laden dauert über 60 s'));
      final load = sw.elapsedMilliseconds;
      report.writeln('Geladen in $load ms.');
      final path = '${tempDir.path}/diag_${DateTime.now().millisecondsSinceEpoch}.wav';
      final c = await w.synth('Hallo! So klinge ich.', path, 1.0).timeout(const Duration(seconds: 45),
          onTimeout: () => throw Exception('Erzeugen dauert über 45 s'));
      report.writeln('Audio: ${c.seconds.toStringAsFixed(1)} s, ${c.sampleRate} Hz, '
          '${File(c.path!).lengthSync()} Bytes, erzeugt in ${sw.elapsedMilliseconds - load} ms.');
      final played = await _play(c);
      report.writeln(played ? 'Wiedergabe gestartet.' : 'Wiedergabe fehlgeschlagen: ${lastError.value}');
      voiceLog('Diagnose OK\n$report');
      return (played, report.toString());
    } catch (e, st) {
      report.writeln('FEHLER: $e');
      voiceLog('Diagnose fehlgeschlagen\n$report$st');
      return (false, report.toString());
    } finally {
      await w?.dispose();
    }
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

  Transcriber? _stt;
  String? _sttPath;

  SileroClassifier? _silero;
  bool _sileroTried = false;

  /// Silero-Sprachklassifikator (erkennt menschliche Sprache, ignoriert Lärm).
  /// null, wenn er auf diesem Gerät nicht geladen werden kann.
  Future<SileroClassifier?> speechClassifier(Directory dir) async {
    if (_sileroTried) return _silero;
    _sileroTried = true;
    _silero = await SileroClassifier.create(dir);
    return _silero;
  }

  Future<Transcriber> stt(String modelPath) async {
    if (_stt != null && _sttPath == modelPath) return _stt!;
    await _stt?.dispose();
    _stt = null;
    // Ordner = sherpa-onnx-Modell (Canary, Parakeet), Datei = Whisper (whisper.cpp)
    _stt = Directory(modelPath).existsSync()
        ? await SherpaAsr.start(modelPath)
        : _WhisperStt(await SttEngine.load(modelPath));
    _sttPath = modelPath;
    return _stt!;
  }

  /// Whisper aus dem Speicher nehmen (nach dem Gesprächsmodus – Platz fürs Sprachmodell).
  Future<void> releaseStt() async {
    final s = _stt;
    _stt = null;
    _sttPath = null;
    await s?.dispose();
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
// Spracherkennung: Whisper (whisper.cpp) oder sherpa-onnx (Canary, Parakeet)
// ===========================================================================

abstract class Transcriber {
  Future<Transcript> transcribe(Float32List pcm16k, {String language = 'auto', int threads = 4});
  Future<void> dispose();
}

class _WhisperStt implements Transcriber {
  _WhisperStt(this._e);
  final SttEngine _e;
  @override
  Future<Transcript> transcribe(Float32List pcm16k, {String language = 'auto', int threads = 4}) =>
      _e.transcribe(pcm16k, language: language, threads: threads);
  @override
  Future<void> dispose() => _e.dispose();
}

/// Schnelle Offline-Erkenner über sherpa-onnx in einem eigenen Isolate.
class SherpaAsr implements Transcriber {
  SherpaAsr._(this._isolate, this._send, this._responses);
  final Isolate _isolate;
  final SendPort _send;
  final Stream<dynamic> _responses;
  int _id = 1;

  static Future<SherpaAsr> start(String dir) async {
    final rp = ReceivePort();
    final errors = ReceivePort();
    final iso = await Isolate.spawn(_asrMain, rp.sendPort, debugName: 'asr', onError: errors.sendPort);
    final responses = rp.asBroadcastStream();
    final crash = Completer<Map>();
    errors.listen((e) {
      if (!crash.isCompleted) crash.complete({'id': 0, 'ok': false, 'error': 'Absturz in der Spracherkennung: $e'});
    });
    final send = await Future.any([responses.first, crash.future.then((m) => throw Exception(m['error']))]) as SendPort;
    final threads = math.max(2, math.min(4, Platform.numberOfProcessors ~/ 2));
    send.send({'cmd': 'load', 'id': 0, 'dir': dir, 'threads': threads});
    final r = await Future.any([
      responses.firstWhere((m) => m is Map && m['id'] == 0).then((m) => m as Map),
      crash.future,
    ]).timeout(const Duration(seconds: 90));
    if (r['ok'] != true) {
      iso.kill(priority: Isolate.immediate);
      throw Exception(r['error'] ?? 'Spracherkennung konnte nicht geladen werden');
    }
    return SherpaAsr._(iso, send, responses);
  }

  @override
  Future<Transcript> transcribe(Float32List pcm16k, {String language = 'auto', int threads = 4}) async {
    final id = _id++;
    final sw = Stopwatch()..start();
    final f = _responses.firstWhere((m) => m is Map && m['id'] == id);
    _send.send({'cmd': 'run', 'id': id, 'pcm': TransferableTypedData.fromList([pcm16k])});
    final r = await f.timeout(const Duration(seconds: 60)) as Map;
    if (r['ok'] != true) throw Exception(r['error'] ?? 'Spracherkennung fehlgeschlagen');
    return Transcript((r['text'] as String).trim(), language == 'auto' ? 'de' : language, sw.elapsed);
  }

  @override
  Future<void> dispose() async {
    _send.send({'cmd': 'dispose', 'id': -1});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

void _asrMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  sherpa.OfflineRecognizer? rec;
  inbox.listen((dynamic msg) {
    final m = msg as Map;
    final id = m['id'];
    try {
      switch (m['cmd']) {
        case 'load':
          _initSherpa();
          final dir = Directory(m['dir'] as String);
          final files = dir.listSync(recursive: true).whereType<File>().map((f) => f.path).toList()..sort();
          String? pick(String part) =>
              files.where((f) => f.endsWith('.onnx') && f.split('/').last.contains(part)).firstOrNull;
          final tokens = files.where((f) => f.endsWith('tokens.txt')).firstOrNull;
          final enc = pick('encoder'), dec = pick('decoder'), join = pick('joiner');
          if (tokens == null || enc == null || dec == null) {
            out.send({'id': id, 'ok': false, 'error': 'Spracherkennung unvollständig (encoder/decoder/tokens fehlen)'});
            return;
          }
          final threads = m['threads'] as int;
          final name = dir.path.toLowerCase();
          final model = join != null
              ? sherpa.OfflineModelConfig(
                  transducer: sherpa.OfflineTransducerModelConfig(encoder: enc, decoder: dec, joiner: join),
                  modelType: 'nemo_transducer',
                  tokens: tokens,
                  numThreads: threads,
                  debug: false)
              : name.contains('canary')
                  ? sherpa.OfflineModelConfig(
                      canary: sherpa.OfflineCanaryModelConfig(encoder: enc, decoder: dec, srcLang: 'de', tgtLang: 'de'),
                      tokens: tokens,
                      numThreads: threads,
                      debug: false)
                  : sherpa.OfflineModelConfig(
                      whisper: sherpa.OfflineWhisperModelConfig(encoder: enc, decoder: dec, language: 'de'),
                      tokens: tokens,
                      numThreads: threads,
                      debug: false);
          rec = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(model: model));
          out.send({'id': id, 'ok': true});
        case 'run':
          final pcm = (m['pcm'] as TransferableTypedData).materialize().asFloat32List();
          final st = rec!.createStream();
          st.acceptWaveform(samples: pcm, sampleRate: 16000);
          rec!.decode(st);
          final text = rec!.getResult(st).text;
          st.free();
          out.send({'id': id, 'ok': true, 'text': text});
        case 'dispose':
          rec?.free();
          rec = null;
          inbox.close();
      }
    } catch (e) {
      out.send({'id': id, 'ok': false, 'error': e.toString()});
    }
  });
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

/// Silero-VAD über sherpa-onnx: entscheidet pro Frame, ob Sprache vorliegt.
class SileroClassifier {
  SileroClassifier._(this._vad);
  final sherpa.VoiceActivityDetector _vad;
  bool _last = false;

  static Future<SileroClassifier?> create(Directory dir) async {
    try {
      _initSherpa();
      final f = File('${dir.path}/silero_vad.onnx');
      final data = await rootBundle.load('assets/vad/silero_vad.onnx');
      if (!f.existsSync() || f.lengthSync() != data.lengthInBytes) {
        await f.parent.create(recursive: true);
        await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      final vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: f.path,
            threshold: 0.5,
            minSilenceDuration: 0.15,
            minSpeechDuration: 0.1,
            windowSize: 512,
            maxSpeechDuration: 60,
          ),
          sampleRate: 16000,
          numThreads: 1,
          debug: false,
        ),
        bufferSizeInSeconds: 10,
      );
      voiceLog('Silero-VAD geladen');
      return SileroClassifier._(vad);
    } catch (e) {
      voiceLog('Silero-VAD nicht verfügbar, nutze Energie-Erkennung: $e');
      return null;
    }
  }

  bool call(Float32List frame) {
    try {
      _vad.acceptWaveform(frame);
      _last = _vad.isDetected();
      while (!_vad.isEmpty()) {
        _vad.pop();
      }
    } catch (_) {}
    return _last;
  }

  void reset() {
    try {
      _vad.reset();
    } catch (_) {}
    _last = false;
  }
}

bool _sherpaReady = false;

/// Lädt die sherpa-onnx-Bibliothek; probiert mehrere Orte (macOS-App-Bundle).
void _initSherpa() {
  if (_sherpaReady) return;
  _initSherpaOnce();
  _sherpaReady = true;
}

void _initSherpaOnce() {
  final errors = <String>[];
  try {
    sherpa.initBindings();
    return;
  } catch (e) {
    errors.add('Standard: $e');
  }
  final candidates = <String>[];
  final exe = File(Platform.resolvedExecutable).parent; // …/Contents/MacOS
  if (Platform.isMacOS) {
    final fw = Directory('${exe.parent.path}/Frameworks');
    candidates.add('${fw.path}/libsherpa-onnx-c-api.dylib');
    try {
      for (final f in fw.listSync(recursive: true).whereType<File>()) {
        if (f.path.endsWith('libsherpa-onnx-c-api.dylib') || f.path.endsWith('/sherpa_onnx_macos')) {
          candidates.add(f.path);
        }
      }
    } catch (e) {
      errors.add('Frameworks nicht lesbar: $e');
    }
  } else if (Platform.isAndroid) {
    candidates.add('libsherpa-onnx-c-api.so');
  }
  for (final c in candidates) {
    try {
      sherpa.initBindings(c);
      return;
    } catch (e) {
      errors.add('$c: $e');
    }
  }
  throw Exception('sherpa-onnx-Bibliothek nicht ladbar:\n${errors.join('\n')}');
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
          _initSherpa();
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
          // Kokoro-Stimmen haben eine voices.bin (Stil-Vektoren), Piper nicht
          final voices = files.where((f) => f.path.endsWith('voices.bin')).firstOrNull;
          final threads = math.max(2, math.min(4, Platform.numberOfProcessors ~/ 2));
          tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
            model: voices != null
                ? sherpa.OfflineTtsModelConfig(
                    kokoro: sherpa.OfflineTtsKokoroModelConfig(
                      model: model.path,
                      voices: voices.path,
                      tokens: tokens.path,
                      dataDir: espeak.path,
                      lang: (m['lang'] as String?) ?? 'de',
                    ),
                    numThreads: threads,
                  )
                : sherpa.OfflineTtsModelConfig(
                    vits: sherpa.OfflineTtsVitsModelConfig(
                      model: model.path,
                      tokens: tokens.path,
                      dataDir: espeak.path,
                    ),
                    numThreads: 2,
                  ),
          ));
          if (tts!.ptr.address == 0) {
            tts = null;
            out.send({'id': id, 'ok': false, 'error': 'sherpa-onnx konnte die Stimme nicht anlegen (Konfiguration abgelehnt)'});
            return;
          }
          // Probelauf: liefert die Stimme überhaupt Audio?
          final probe = tts!.generate(text: 'Test.', speed: 1.0);
          if (probe.samples.isEmpty) {
            out.send({'id': id, 'ok': false, 'error': 'Stimme geladen, erzeugt aber kein Audio (Phonemisierung fehlgeschlagen)'});
            return;
          }
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
