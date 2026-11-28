// Mitschrift: Sprecher unterscheiden (Stimm-Fingerabdruck), Musik und Geräusche erkennen,
// Aufnahme als WAV sichern. Alles auf dem Gerät (sherpa-onnx); die Modelle werden einmal geladen.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'voice_service.dart' show appLog, ensureSherpa;

/// Zusatzmodelle für die Mitschrift (≈ 57 MB): Stimm-Fingerabdruck (CAM++) und Geräusche (CED tiny, AudioSet).
class MeetingModels {
  MeetingModels(this.dir);
  final Directory dir;

  static const speakerUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx';
  static const taggingUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/audio-tagging-models/sherpa-onnx-ced-tiny-audio-tagging-2024-04-19.tar.bz2';
  static const taggingFolder = 'sherpa-onnx-ced-tiny-audio-tagging-2024-04-19';
  static const sizeMb = 57;

  File get speakerModel => File('${dir.path}/speaker-campplus.onnx');
  Directory get _tagDir => Directory('${dir.path}/$taggingFolder');
  File get taggingModel {
    final int8 = File('${_tagDir.path}/model.int8.onnx');
    return int8.existsSync() ? int8 : File('${_tagDir.path}/model.onnx');
  }

  File get taggingLabels => File('${_tagDir.path}/class_labels_indices.csv');

  bool get installed => speakerModel.existsSync() && taggingModel.existsSync() && taggingLabels.existsSync();

  /// Lädt beide Modelle (nur auf ausdrücklichen Wunsch – Knopf in der Mitschrift).
  Future<void> download({
    required Downloader downloader,
    required Future<void> Function(String archive, String dir) extract,
    void Function(double progress, String what)? onProgress,
    CancelToken? cancel,
  }) async {
    dir.createSync(recursive: true);
    if (!speakerModel.existsSync()) {
      final tmp = '${speakerModel.path}.part';
      final f = await downloader.download(speakerUrl, tmp, cancel: cancel, onProgress: (p) => onProgress?.call((p.fraction ?? 0) * 0.5, 'Sprecher-Erkennung'));
      await f.rename(speakerModel.path);
    }
    if (!taggingModel.existsSync() || !taggingLabels.existsSync()) {
      final archive = '${dir.path}/tagging.tar.bz2';
      final f = await downloader.download(taggingUrl, archive, cancel: cancel, onProgress: (p) => onProgress?.call(0.5 + (p.fraction ?? 0) * 0.45, 'Musik & Geräusche'));
      onProgress?.call(0.97, 'Entpacken');
      await extract(f.path, dir.path);
      await f.delete();
      // große Fassung entfernen, wenn die kleine (int8) da ist
      final big = File('${_tagDir.path}/model.onnx');
      if (File('${_tagDir.path}/model.int8.onnx').existsSync() && big.existsSync()) await big.delete();
      final testWavs = Directory('${_tagDir.path}/test_wavs');
      if (testWavs.existsSync()) await testWavs.delete(recursive: true);
    }
    onProgress?.call(1, 'Fertig');
  }

  sherpa.SpeakerEmbeddingExtractor? _extractor;
  sherpa.AudioTagging? _tagger;
  bool _tried = false;

  /// Modelle laden (falls vorhanden). Ohne Modelle: keine Sprecher-/Geräuscherkennung.
  bool load({int threads = 2}) {
    if (_extractor != null) return true;
    if (_tried || !installed) return false;
    _tried = true;
    try {
      ensureSherpa();
      _extractor = sherpa.SpeakerEmbeddingExtractor(
          config: sherpa.SpeakerEmbeddingExtractorConfig(model: speakerModel.path, numThreads: threads, debug: false));
      _tagger = sherpa.AudioTagging(
          config: sherpa.AudioTaggingConfig(
              model: sherpa.AudioTaggingModelConfig(ced: taggingModel.path, numThreads: threads, debug: false), labels: taggingLabels.path));
      appLog('Mitschrift', 'Sprecher- und Geräuscherkennung geladen');
      return true;
    } catch (e) {
      appLog('Mitschrift', 'Sprecher-/Geräuscherkennung nicht verfügbar: $e', error: true);
      _extractor = null;
      _tagger = null;
      return false;
    }
  }

  bool get ready => _extractor != null;

  /// Stimm-Fingerabdruck (normiert) oder null
  Float32List? embed(Float32List pcm) {
    final x = _extractor;
    if (x == null || pcm.length < 16000 * 0.8) return null;
    try {
      final s = x.createStream();
      s.acceptWaveform(samples: pcm, sampleRate: 16000);
      s.inputFinished();
      Float32List? e;
      if (x.isReady(s)) e = x.compute(s);
      s.free();
      if (e == null || e.isEmpty) return null;
      return _norm(Float32List.fromList(e));
    } catch (e) {
      appLog('Mitschrift', 'Fingerabdruck: $e', error: true);
      return null;
    }
  }

  /// Was ist zu hören? (AudioSet-Namen mit Wahrscheinlichkeit)
  List<(String, double)> tag(Float32List pcm, {int topK = 6}) {
    final t = _tagger;
    if (t == null || pcm.length < 16000 * 0.5) return const [];
    try {
      // höchstens 10 s aus der Mitte – reicht und bleibt schnell
      var x = pcm;
      if (x.length > 160000) {
        final s = (x.length - 160000) ~/ 2;
        x = Float32List.sublistView(x, s, s + 160000);
      }
      final st = t.createStream();
      st.acceptWaveform(samples: Float32List.fromList(x), sampleRate: 16000);
      final r = t.compute(stream: st, topK: topK);
      st.free();
      return [for (final e in r) (e.name, e.prob)];
    } catch (e) {
      appLog('Mitschrift', 'Geräusche: $e', error: true);
      return const [];
    }
  }

  void dispose() {
    try {
      _extractor?.free();
      _tagger?.free();
    } catch (_) {}
    _extractor = null;
    _tagger = null;
    _tried = false;
  }
}

Float32List _norm(Float32List v) {
  var s = 0.0;
  for (final x in v) {
    s += x * x;
  }
  final n = math.sqrt(s);
  if (n > 0) {
    for (var i = 0; i < v.length; i++) {
      v[i] /= n;
    }
  }
  return v;
}

double cosine(Float32List a, Float32List b) {
  var s = 0.0;
  for (var i = 0; i < math.min(a.length, b.length); i++) {
    s += a[i] * b[i];
  }
  return s;
}

/// Ordnet Abschnitte Sprechern zu (laufende Zuordnung über den Stimm-Fingerabdruck).
class SpeakerTracker {
  SpeakerTracker({this.threshold = 0.5, this.maxSpeakers = 8});
  final double threshold;
  final int maxSpeakers;
  final centroids = <Float32List>[];
  final counts = <int>[];

  void reset() {
    centroids.clear();
    counts.clear();
  }

  /// Sprecher-Nummer; [previous] hilft bei kurzen, unsicheren Abschnitten.
  int assign(Float32List emb, {required double seconds, int previous = -1}) {
    var best = -1;
    var bestSim = -1.0;
    for (var i = 0; i < centroids.length; i++) {
      final s = cosine(emb, centroids[i]);
      if (s > bestSim) {
        bestSim = s;
        best = i;
      }
    }
    // kurze Abschnitte sind unsicher: lieber beim letzten Sprecher bleiben
    final thr = seconds < 2.5 ? threshold - 0.1 : threshold;
    if (best >= 0 && bestSim >= thr) {
      _update(best, emb);
      return best;
    }
    if (seconds < 1.5 && previous >= 0) return previous;
    if (centroids.length < maxSpeakers) {
      centroids.add(Float32List.fromList(emb));
      counts.add(1);
      return centroids.length - 1;
    }
    _update(best, emb);
    return best;
  }

  void _update(int i, Float32List emb) {
    final c = centroids[i];
    final n = counts[i];
    for (var k = 0; k < c.length; k++) {
      c[k] = (c[k] * n + emb[k]) / (n + 1);
    }
    _norm(c);
    counts[i] = math.min(n + 1, 50); // neue Abschnitte zählen weiter mit
  }

  /// Sprecher [from] in [into] aufgehen lassen
  void merge(int from, int into) {
    if (from < 0 || into < 0 || from >= centroids.length || into >= centroids.length || from == into) return;
    for (var k = 0; k < centroids[into].length; k++) {
      centroids[into][k] += centroids[from][k];
    }
    _norm(centroids[into]);
  }
}

/// Was die Geräuscherkennung meldet → (Art, Beschriftung) oder null für Sprache
(String, String)? soundKind(List<(String, double)> tags) {
  if (tags.isEmpty) return null;
  double p(bool Function(String) f) => tags.where((t) => f(t.$1)).fold(0.0, (m, t) => math.max(m, t.$2));
  final speech = p((n) => n == 'Speech' || n.contains('conversation') || n == 'Narration, monologue');
  final music = p((n) => n.contains('Music') || n.contains('music') || n == 'Musical instrument' || n == 'Song' || n.contains('Guitar') || n.contains('Piano') || n.contains('Drum'));
  final singing = p((n) => n == 'Singing' || n == 'Choir' || n.contains('singing'));
  if ((music > 0.35 || singing > 0.35) && math.max(music, singing) > speech) return ('music', singing > music ? 'Gesang' : 'Musik');
  if (speech >= 0.3) return null;
  const de = {
    'Applause': 'Applaus',
    'Clapping': 'Klatschen',
    'Laughter': 'Lachen',
    'Cheering': 'Jubel',
    'Telephone': 'Telefon',
    'Ringtone': 'Klingelton',
    'Telephone bell ringing': 'Telefon klingelt',
    'Alarm': 'Alarm',
    'Dog': 'Hund',
    'Bark': 'Bellen',
    'Door': 'Tür',
    'Knock': 'Klopfen',
    'Typing': 'Tippen',
    'Computer keyboard': 'Tastatur',
    'Vehicle': 'Fahrzeug',
    'Traffic noise, roadway noise': 'Verkehr',
    'Engine': 'Motor',
    'Crowd': 'Menschenmenge',
    'Chatter': 'Stimmengewirr',
    'Cough': 'Husten',
    'Baby cry, infant cry': 'Babyweinen',
    'Television': 'Fernseher',
    'Radio': 'Radio',
    'Rain': 'Regen',
    'Wind': 'Wind',
    'Beep, bleep': 'Piepton',
    'Siren': 'Sirene',
  };
  for (final (name, prob) in tags) {
    if (prob < 0.3) break;
    if (name == 'Silence' || name.startsWith('Inside') || name.startsWith('Outside') || name == 'Speech') continue;
    final d = de[name];
    if (d != null) return ('sound', d);
  }
  return null;
}

/// Whisper-Anmerkungen wie „[Musik]“, „(Applaus)“, „♪“ → (Art, Beschriftung)
(String, String)? whisperMarker(String text) {
  final t = text.trim();
  if (t.contains('♪') || RegExp(r'^[\[(*]\s*(musik|music|gesang|singing)', caseSensitive: false).hasMatch(t)) return ('music', 'Musik');
  final m = RegExp(r'^[\[(*]\s*([^\])*]{2,30})\s*[\])*]$').firstMatch(t);
  if (m != null) {
    final w = m.group(1)!.trim();
    if (RegExp(r'untertitel|subtitle|amara|stille|silence|^blank', caseSensitive: false).hasMatch(w)) return ('skip', '');
    return ('sound', w[0].toUpperCase() + w.substring(1));
  }
  // bekannte Whisper-Halluzinationen bei Musik/Stille
  if (RegExp(r'^(untertitel (im auftrag|der amara)|vielen dank fürs zuschauen|copyright wdr|swr \d{4})', caseSensitive: false).hasMatch(t)) {
    return ('skip', '');
  }
  return null;
}

/// Schreibt die Aufnahme laufend als WAV (16 kHz, mono, 16 bit).
class WavWriter {
  WavWriter(this.file);
  final File file;
  RandomAccessFile? _raf;
  int samples = 0;

  void open() {
    file.parent.createSync(recursive: true);
    _raf = file.openSync(mode: FileMode.write);
    _raf!.writeFromSync(_header(0));
    samples = 0;
  }

  void add(Float32List frame) {
    final r = _raf;
    if (r == null) return;
    final b = Int16List(frame.length);
    for (var i = 0; i < frame.length; i++) {
      b[i] = (frame[i].clamp(-1.0, 1.0) * 32767).round();
    }
    r.writeFromSync(b.buffer.asUint8List());
    samples += frame.length;
  }

  void close() {
    final r = _raf;
    if (r == null) return;
    _raf = null;
    try {
      r.setPositionSync(0);
      r.writeFromSync(_header(samples * 2));
      r.closeSync();
    } catch (_) {}
  }

  static Uint8List _header(int dataBytes) {
    final h = ByteData(44);
    void str(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        h.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    h.setUint32(4, 36 + dataBytes, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, 16000, Endian.little);
    h.setUint32(28, 32000, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    str(36, 'data');
    h.setUint32(40, dataBytes, Endian.little);
    return h.buffer.asUint8List();
  }
}
