// Sprache: Aufnahme (record) → Whisper (whisper.cpp) und
// Vorlesen mit Piper (sherpa-onnx) → Wiedergabe (audioplayers).
// Alles lokal; Modelle kommen aus dem Systemcheck-Download.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_engine/agent_engine.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

enum VoicePhase { idle, recording, transcribing }

class VoiceService {
  VoiceService(this.tempDir);

  final Directory tempDir;

  final phase = ValueNotifier<VoicePhase>(VoicePhase.idle);
  final level = ValueNotifier<double>(0); // 0..1 Lautstärke beim Aufnehmen
  final recordSeconds = ValueNotifier<int>(0);

  /// Index der Chat-Nachricht, die gerade vorgelesen wird (null = keine).
  final speakingKey = ValueNotifier<Object?>(null);

  AudioRecorder? _recorder;
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _timer;
  String? _recordPath;

  SttEngine? _stt;
  String? _sttPath;

  _TtsWorker? _tts;
  String? _ttsDir;
  final AudioPlayer _player = AudioPlayer();
  int _speakGeneration = 0;
  Completer<void>? _playDone;

  // ------------------------------------------------------------ Spracherkennung

  Future<void> _ensureStt(String modelPath) async {
    if (_stt != null && _sttPath == modelPath) return;
    await _stt?.dispose();
    _stt = null;
    _stt = await SttEngine.load(modelPath);
    _sttPath = modelPath;
  }

  /// Lädt Whisper vorab (z. B. direkt nach dem Download).
  Future<void> preloadStt(String modelPath) => _ensureStt(modelPath);

  Future<bool> hasMicPermission() async {
    final r = _recorder ??= AudioRecorder();
    return r.hasPermission();
  }

  Future<void> startRecording() async {
    if (phase.value != VoicePhase.idle) return;
    await stopSpeaking();
    final r = _recorder ??= AudioRecorder();
    if (!await r.hasPermission()) {
      throw Exception('Kein Zugriff auf das Mikrofon. Bitte in den Systemeinstellungen erlauben.');
    }
    _recordPath = '${tempDir.path}/aufnahme_${DateTime.now().millisecondsSinceEpoch}.wav';
    await r.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ),
      path: _recordPath!,
    );
    recordSeconds.value = 0;
    phase.value = VoicePhase.recording;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      recordSeconds.value = t.tick;
      if (t.tick >= 120) unawaited(r.stop()); // Sicherheitsgrenze 2 Minuten
    });
    _ampSub = r.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
      // dBFS (-60..0) → 0..1
      level.value = ((a.current + 60) / 60).clamp(0.0, 1.0);
    });
  }

  Future<void> cancelRecording() async {
    _timer?.cancel();
    await _ampSub?.cancel();
    await _recorder?.cancel();
    phase.value = VoicePhase.idle;
    level.value = 0;
  }

  /// Beendet die Aufnahme und liefert den erkannten Text.
  Future<Transcript> stopAndTranscribe({
    required String modelPath,
    required String language,
    required int threads,
  }) async {
    _timer?.cancel();
    await _ampSub?.cancel();
    level.value = 0;
    final path = await _recorder?.stop() ?? _recordPath;
    phase.value = VoicePhase.transcribing;
    try {
      if (path == null || !File(path).existsSync()) throw Exception('Keine Aufnahme vorhanden');
      final pcm = decodeWavTo16kMono(await File(path).readAsBytes());
      if (pcm.length < 16000 * 0.4) throw Exception('Aufnahme zu kurz');
      await _ensureStt(modelPath);
      final t = await _stt!.transcribe(pcm, language: language, threads: threads);
      return t;
    } finally {
      phase.value = VoicePhase.idle;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }

  // --------------------------------------------------------------- Vorlesen

  /// Liest [text] satzweise vor. Der nächste Satz wird erzeugt, während der
  /// vorherige noch spielt.
  Future<void> speak(String text, {required String voiceDir, Object? key, double speed = 1.0}) async {
    await stopSpeaking();
    final generation = ++_speakGeneration;
    speakingKey.value = key ?? text.hashCode;
    try {
      if (_tts == null || _ttsDir != voiceDir) {
        await _tts?.dispose();
        _tts = await _TtsWorker.start(voiceDir);
        _ttsDir = voiceDir;
      }
      final sentences = splitForSpeech(cleanForSpeech(text));
      Future<String?> synth(int i) async {
        if (i >= sentences.length || generation != _speakGeneration) return null;
        return _tts!.synth(sentences[i], '${tempDir.path}/tts_${generation}_$i.wav', speed);
      }

      var next = synth(0);
      for (var i = 0; i < sentences.length; i++) {
        final file = await next;
        if (file == null || generation != _speakGeneration) break;
        next = synth(i + 1); // parallel vorbereiten
        if (file.isEmpty) continue; // Satz ohne hörbaren Inhalt
        final done = _playDone = Completer<void>();
        final sub = _player.onPlayerComplete.listen((_) {
          if (!done.isCompleted) done.complete();
        });
        try {
          await _player.play(DeviceFileSource(file));
          await done.future.timeout(const Duration(minutes: 3), onTimeout: () {});
        } finally {
          await sub.cancel();
        }
        unawaited(File(file).delete().catchError((_) => File(file)));
      }
    } finally {
      if (generation == _speakGeneration) speakingKey.value = null;
    }
  }

  Future<void> stopSpeaking() async {
    _speakGeneration++;
    speakingKey.value = null;
    final d = _playDone;
    if (d != null && !d.isCompleted) d.complete();
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await cancelRecording();
    await stopSpeaking();
    await _stt?.dispose();
    await _tts?.dispose();
    await _player.dispose();
    await _recorder?.dispose();
  }

  /// Markdown, Code und Links in vorlesbaren Text verwandeln.
  static String cleanForSpeech(String md) {
    var s = md.replaceAll(RegExp(r'```.*?```', dotAll: true), ' (Codeblock ausgelassen) ');
    s = s.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!);
    s = s.replaceAllMapped(RegExp(r'https?://([^/\s]+)\S*'), (m) => m[1]!);
    s = s.replaceAll(RegExp(r'^\s*\|.*\|\s*$', multiLine: true), ' ');
    s = s.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    s = s.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
    s = s.replaceAll(RegExp(r'[*_`>#]'), '');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Zerlegt in Sätze (max. ~300 Zeichen pro Stück).
  static List<String> splitForSpeech(String text) {
    final parts = <String>[];
    // nur an Satzzeichen mit folgendem Leerraum trennen (nicht in "example.com" oder "3.5")
    for (final raw in text.split(RegExp(r'(?<=[.!?;:])\s+'))) {
      var p = raw.trim();
      if (p.isEmpty) continue;
      while (p.length > 300) {
        final cut = p.lastIndexOf(RegExp(r'[,\s]'), 300);
        final at = cut > 100 ? cut : 300;
        parts.add(p.substring(0, at).trim());
        p = p.substring(at).trim();
      }
      if (parts.isNotEmpty && parts.last.length < 40) {
        parts[parts.length - 1] = '${parts.last} $p';
      } else {
        parts.add(p);
      }
    }
    return parts;
  }
}

// ----------------------------------------------------------------- Piper-Isolate

class _TtsWorker {
  _TtsWorker(this._isolate, this._send, this._responses);
  final Isolate _isolate;
  final SendPort _send;
  final Stream<dynamic> _responses;
  int _id = 1;

  static Future<_TtsWorker> start(String voiceDir) async {
    final rp = ReceivePort();
    final iso = await Isolate.spawn(_ttsMain, rp.sendPort, debugName: 'piper');
    final responses = rp.asBroadcastStream();
    final send = await responses.first as SendPort;
    send.send({'cmd': 'load', 'id': 0, 'dir': voiceDir});
    final r = await responses.firstWhere((m) => m is Map && m['id'] == 0) as Map;
    if (r['ok'] != true) {
      iso.kill(priority: Isolate.immediate);
      throw Exception(r['error'] ?? 'Stimme konnte nicht geladen werden');
    }
    return _TtsWorker(iso, send, responses);
  }

  Future<String?> synth(String text, String outPath, double speed) async {
    final id = _id++;
    final f = _responses.firstWhere((m) => m is Map && m['id'] == id);
    _send.send({'cmd': 'synth', 'id': id, 'text': text, 'out': outPath, 'speed': speed});
    final r = await f as Map;
    if (r['ok'] != true) throw Exception(r['error'] ?? 'Sprachausgabe fehlgeschlagen');
    return r['path'] as String? ?? '';
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
          final files = dir.listSync().whereType<File>().toList();
          final model = files.where((f) => f.path.endsWith('.onnx')).firstOrNull;
          final tokens = files.where((f) => f.path.endsWith('tokens.txt')).firstOrNull;
          final espeak = Directory('${dir.path}/espeak-ng-data');
          if (model == null || tokens == null || !espeak.existsSync()) {
            out.send({'id': id, 'ok': false, 'error': 'Stimme unvollständig (onnx/tokens/espeak-ng-data fehlen)'});
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
          if (audio.samples.isEmpty) {
            out.send({'id': id, 'ok': true, 'path': null});
            return;
          }
          final path = m['out'] as String;
          File(path).writeAsBytesSync(encodeWav16(audio.samples, audio.sampleRate));
          out.send({'id': id, 'ok': true, 'path': path});
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
