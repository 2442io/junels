// Einfache Sprach-Erkennung (VAD) und Satzende-Erkennung auf PCM-Frames.
// Energiebasiert mit adaptiver Rauschschwelle – genügt für Gesprächsmodus
// und Unterbrechen, ohne weiteres Modell.

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
  });

  final int sampleRate;
  final int frameMs;
  final int startMs; // so lange muss Sprache anliegen, bis "Start"
  final int endSilenceMs; // so lange Stille beendet die Äußerung
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

  void reset() {
    _inSpeech = false;
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
      final voiced = db > threshold && db > -50;
      if (!_inSpeech) {
        // Grundrauschen langsam nachführen (nur in Ruhe)
        if (!voiced) _noiseDb = _noiseDb * 0.95 + db * 0.05;
        _preRoll.addAll(frame);
        final maxPre = sampleRate * 300 ~/ 1000;
        if (_preRoll.length > maxPre) _preRoll.removeRange(0, _preRoll.length - maxPre);
        _speechRun = voiced ? _speechRun + frameMs : 0;
        if (_speechRun >= startMs) {
          _inSpeech = true;
          _silenceRun = 0;
          _uttMs = _speechRun;
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
        if (_silenceRun >= endSilenceMs || _uttMs >= maxUtteranceMs) {
          _inSpeech = false;
          _speechRun = 0;
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
