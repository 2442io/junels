// Sprach-Erkennung (VAD) und Satzende-Erkennung auf PCM-Frames.
// Grundlage ist eine adaptive Rauschschwelle. Optional entscheidet ein
// Sprach-Klassifikator (z. B. Silero) pro Frame, ob überhaupt Sprache vorliegt –
// so lösen U-Bahn-Lärm, Musik oder Klappern nichts aus. Der Nahfeld-Filter
// ignoriert leisere Stimmen im Hintergrund (andere Personen), weil die eigene
// Stimme am Mikrofon deutlich lauter ankommt.

import 'dart:math' as math;
import 'dart:typed_data';

enum VadEvent { none, speechStart, speechEnd }

class VoiceActivityDetector {
  VoiceActivityDetector({
    this.sampleRate = 16000,
    this.frameMs = 30,
    this.startMs = 150,
    this.endSilenceMs = 800,
    this.minSpeechMs = 300,
    this.maxUtteranceMs = 30000,
    this.marginDb = 12,
    this.classifier,
    this.nearFieldDb = 0,
    this.preRollMs = 300,
  });

  /// So viel Ton vor dem erkannten Start wird mitgenommen (erstes Wort nicht abschneiden).
  final int preRollMs;

  /// Liefert pro Frame, ob darin menschliche Sprache steckt (null = nur Energie).
  bool Function(Float32List frame)? classifier;

  /// > 0: Frames, die so viele dB leiser sind als die eigene Stimme, gelten als Stille.
  double nearFieldDb;

  /// Absender-Modus: Äußerung endet nicht bei einer Pause, sondern erst mit [finish].
  bool manual = false;

  double? _voiceDb; // typischer Pegel der eigenen Stimme (gelernt)
  double _uttVoiceSum = 0;
  int _uttVoiceN = 0;

  final int sampleRate;
  final int frameMs;
  final int startMs; // so lange muss Sprache anliegen, bis "Start"
  int endSilenceMs; // so lange Stille beendet die Äußerung
  final int minSpeechMs; // kürzere Geräusche werden verworfen
  final int maxUtteranceMs;
  double marginDb; // Abstand über Grundrauschen

  /// Zusätzlicher Abstand, z. B. während der Agent spricht (Echo).
  double extraMarginDb = 0;

  double _noiseDb = -55;
  bool _inSpeech = false;
  int _speechRun = 0, _silenceRun = 0, _uttMs = 0;
  final List<double> _pending = [];
  final List<double> _utterance = [];
  final List<double> _preRoll = []; // Audio kurz vor dem Start mitnehmen

  bool get inSpeech => _inSpeech;
  double lastDb = -90;

  int get _frameLen => sampleRate * frameMs ~/ 1000;

  /// Fertige Äußerung (16 kHz mono) nach [VadEvent.speechEnd].
  Float32List takeUtterance() {
    final u = Float32List.fromList(_utterance);
    _utterance.clear();
    return u;
  }

  /// Absender-Modus: Äußerung jetzt abschließen. true, wenn genug Sprache vorlag
  /// (dann liegt sie bei [takeUtterance] bereit).
  bool finish() {
    if (!_inSpeech) return false;
    _inSpeech = false;
    _speechRun = 0;
    _learnVoice();
    final ok = _uttMs - _silenceRun >= minSpeechMs || _uttVoiceN * frameMs >= minSpeechMs;
    if (!ok) _utterance.clear();
    return ok;
  }

  void _learnVoice() {
    if (_uttVoiceN < 5) return;
    final avg = _uttVoiceSum / _uttVoiceN;
    _voiceDb = _voiceDb == null ? avg : _voiceDb! * 0.7 + avg * 0.3;
  }

  void reset() {
    _inSpeech = false;
    _uttVoiceSum = 0;
    _uttVoiceN = 0;
    _speechRun = _silenceRun = _uttMs = 0;
    _pending.clear();
    _utterance.clear();
    _preRoll.clear();
  }

  /// Verarbeitet Samples; gibt das wichtigste Ereignis dieses Aufrufs zurück.
  VadEvent add(Float32List samples) {
    var ev = VadEvent.none;
    _pending.addAll(samples);
    final fl = _frameLen;
    while (_pending.length >= fl) {
      final frame = _pending.sublist(0, fl);
      _pending.removeRange(0, fl);
      var sum = 0.0;
      for (final v in frame) {
        sum += v * v;
      }
      final db = 10 * math.log(sum / fl + 1e-12) / math.ln10;
      lastDb = db;
      final threshold = _noiseDb + marginDb + extraMarginDb;
      var voiced = db > threshold && db > -50;
      final c = classifier;
      if (c != null) {
        // Klassifikator entscheidet über "Sprache ja/nein"; Energie nur als Mindestpegel
        final speech = c(Float32List.fromList(frame));
        voiced = speech && db > _noiseDb + 3 + extraMarginDb && db > -60;
      }
      if (voiced && nearFieldDb > 0) {
        final ref = _inSpeech && _uttVoiceN >= 5 ? math.max(_uttVoiceSum / _uttVoiceN, _voiceDb ?? -90) : _voiceDb;
        if (ref != null && db < ref - nearFieldDb) voiced = false;
      }
      if (!_inSpeech) {
        // Grundrauschen langsam nachführen (nur in Ruhe)
        if (!voiced) _noiseDb = _noiseDb * 0.95 + db * 0.05;
        _preRoll.addAll(frame);
        final maxPre = sampleRate * preRollMs ~/ 1000;
        if (_preRoll.length > maxPre) _preRoll.removeRange(0, _preRoll.length - maxPre);
        _speechRun = voiced ? _speechRun + frameMs : 0;
        if (_speechRun >= startMs) {
          _inSpeech = true;
          _silenceRun = 0;
          _uttMs = _speechRun;
          _uttVoiceSum = 0;
          _uttVoiceN = 0;
          _utterance
            ..clear()
            ..addAll(_preRoll);
          _preRoll.clear();
          ev = VadEvent.speechStart;
        }
      } else {
        _utterance.addAll(frame);
        _uttMs += frameMs;
        _silenceRun = voiced ? 0 : _silenceRun + frameMs;
        if (voiced) {
          _uttVoiceSum += db;
          _uttVoiceN++;
        }
        final limit = manual ? maxUtteranceMs * 4 : maxUtteranceMs;
        if ((!manual && _silenceRun >= endSilenceMs) || _uttMs >= limit) {
          _inSpeech = false;
          _speechRun = 0;
          _learnVoice();
          if (_uttMs - _silenceRun >= minSpeechMs) {
            ev = VadEvent.speechEnd;
          } else {
            _utterance.clear();
          }
        }
      }
    }
    return ev;
  }
}
