// Spracherkennung mit whisper.cpp in einem eigenen Isolate.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'bindings.dart';
import 'llama_engine.dart' show EngineException;

class Transcript {
  Transcript(this.text, this.language, this.duration);
  final String text;
  final String language;
  final Duration duration;
}

class SttEngine {
  SttEngine._(this._isolate, this._send, this._responses, this._ptr, this.modelPath);

  final Isolate _isolate;
  final SendPort _send;
  final Stream<dynamic> _responses;
  final int _ptr;
  final String modelPath;
  int _nextId = 1;
  bool _disposed = false;

  /// Lädt ein Whisper-Modell (ggml-*.bin). [useGpu]: Metal auf Apple-Geräten.
  static Future<SttEngine> load(String modelPath, {bool? useGpu}) async {
    final gpu = useGpu ?? (Platform.isMacOS || Platform.isIOS);
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(_sttMain, receive.sendPort, debugName: 'whisper');
    final responses = receive.asBroadcastStream();
    final send = await responses.first as SendPort;
    send.send({'cmd': 'load', 'id': 0, 'path': modelPath, 'gpu': gpu ? 1 : 0});
    final res = await responses.firstWhere((m) => m is Map && m['id'] == 0) as Map;
    if (res['ok'] != true) {
      isolate.kill(priority: Isolate.immediate);
      receive.close();
      throw EngineException(res['error'] as String? ?? 'Whisper konnte nicht geladen werden');
    }
    return SttEngine._(isolate, send, responses, res['ptr'] as int, modelPath);
  }

  /// Transkribiert 16-kHz-Mono-Audio. [language]: "auto", "de", "en", …
  Future<Transcript> transcribe(Float32List pcm16k, {String language = 'auto', int threads = 4}) async {
    if (_disposed) throw EngineException('Whisper wurde bereits freigegeben');
    final id = _nextId++;
    final sw = Stopwatch()..start();
    final fut = _responses.firstWhere((m) => m is Map && m['id'] == id);
    _send.send({
      'cmd': 'run',
      'id': id,
      'pcm': TransferableTypedData.fromList([pcm16k]),
      'lang': language,
      'threads': threads,
    });
    final r = await fut as Map;
    if (r['ok'] != true) throw EngineException(r['error'] as String? ?? 'Transkription fehlgeschlagen');
    return Transcript(r['text'] as String, r['lang'] as String, sw.elapsed);
  }

  void stop() {
    if (!_disposed && _ptr != 0) NativeEngine.instance.sttStop(Pointer<Void>.fromAddress(_ptr));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    stop();
    final id = _nextId++;
    final fut = _responses.firstWhere((m) => m is Map && m['id'] == id);
    _send.send({'cmd': 'dispose', 'id': id});
    try {
      await fut.timeout(const Duration(seconds: 10));
    } catch (_) {}
    _disposed = true;
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  /// Freier Speicherplatz am Ort von [path] in Bytes (-1 = unbekannt).
  static int freeDiskBytes(String path) {
    final p = toNativeUtf8(path);
    try {
      return NativeEngine.instance.freeDisk(p);
    } finally {
      nativeFree(p);
    }
  }
}

void _sttMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  final n = NativeEngine.instance;
  Pointer<Void> stt = nullptr;

  inbox.listen((dynamic msg) {
    final m = msg as Map;
    final id = m['id'];
    switch (m['cmd']) {
      case 'load':
        final path = toNativeUtf8(m['path'] as String);
        final err = nativeAlloc<Uint8>(512);
        stt = n.sttCreate(path, m['gpu'] as int, err, 512);
        out.send(stt.address == 0
            ? {'id': id, 'ok': false, 'error': fromNativeUtf8(err)}
            : {'id': id, 'ok': true, 'ptr': stt.address});
        nativeFree(path);
        nativeFree(err);
      case 'run':
        final pcm = (m['pcm'] as TransferableTypedData).materialize().asFloat32List();
        final buf = nativeAlloc<Float>(pcm.length * 4);
        buf.asTypedList(pcm.length).setAll(0, pcm);
        final lang = toNativeUtf8(m['lang'] as String);
        try {
          final text = callWithBuffer(
              (b, l) => n.sttTranscribe(stt, buf, pcm.length, lang, m['threads'] as int, b, l),
              initial: 16384);
          final error = fromNativeUtf8(n.sttLastError(stt));
          if (error.isNotEmpty) {
            out.send({'id': id, 'ok': false, 'error': error});
          } else {
            out.send({'id': id, 'ok': true, 'text': text, 'lang': fromNativeUtf8(n.sttLanguage(stt))});
          }
        } finally {
          nativeFree(buf);
          nativeFree(lang);
        }
      case 'dispose':
        if (stt.address != 0) n.sttDestroy(stt);
        stt = nullptr;
        out.send({'id': id, 'ok': true});
        inbox.close();
    }
  });
}

/// Liest eine WAV-Datei (PCM 16 bit oder float32, beliebige Rate/Kanäle)
/// und liefert 16-kHz-Mono-Samples für Whisper.
Float32List decodeWavTo16kMono(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  if (bytes.length < 44 || String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') {
    throw const FormatException('Keine WAV-Datei');
  }
  var pos = 12;
  int channels = 1, rate = 16000, bits = 16, format = 1;
  int dataStart = -1, dataLen = 0;
  while (pos + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final size = bd.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      format = bd.getUint16(body, Endian.little);
      channels = bd.getUint16(body + 2, Endian.little);
      rate = bd.getUint32(body + 4, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE && size >= 26) format = bd.getUint16(body + 24, Endian.little);
    } else if (id == 'data') {
      dataStart = body;
      // manche Rekorder schreiben 0 oder 0xFFFFFFFF als Länge
      dataLen = (size == 0 || size == 0xFFFFFFFF || body + size > bytes.length) ? bytes.length - body : size;
      break;
    }
    pos = body + size + (size.isOdd ? 1 : 0);
  }
  if (dataStart < 0) throw const FormatException('WAV ohne Daten');
  final bytesPerSample = bits ~/ 8;
  final frames = dataLen ~/ (bytesPerSample * channels);
  final mono = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      final o = dataStart + (i * channels + c) * bytesPerSample;
      if (format == 3 && bits == 32) {
        sum += bd.getFloat32(o, Endian.little);
      } else if (bits == 16) {
        sum += bd.getInt16(o, Endian.little) / 32768.0;
      } else if (bits == 32) {
        sum += bd.getInt32(o, Endian.little) / 2147483648.0;
      } else if (bits == 8) {
        sum += (bd.getUint8(o) - 128) / 128.0;
      }
    }
    mono[i] = sum / channels;
  }
  return resampleLinear(mono, rate, 16000);
}

/// Einfaches lineares Resampling (für Sprache ausreichend).
Float32List resampleLinear(Float32List input, int fromRate, int toRate) {
  if (fromRate == toRate || input.isEmpty) return input;
  final outLen = (input.length * toRate / fromRate).floor();
  final out = Float32List(outLen);
  final step = fromRate / toRate;
  for (var i = 0; i < outLen; i++) {
    final x = i * step;
    final i0 = x.floor();
    final i1 = i0 + 1 < input.length ? i0 + 1 : i0;
    final t = x - i0;
    out[i] = input[i0] * (1 - t) + input[i1] * t;
  }
  return out;
}

/// Schreibt Float-Samples als 16-bit-PCM-WAV (z. B. für die TTS-Ausgabe).
Uint8List encodeWav16(Float32List samples, int sampleRate) {
  final dataLen = samples.length * 2;
  final b = ByteData(44 + dataLen);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}
