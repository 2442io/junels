// Gesprächsmodus: freihändig sprechen wie mit einem Menschen.
//
//  zuhören → (Sprechpause oder „Fertig“) → Whisper → Agent → satzweise vorlesen → zuhören
//
// Spricht der Nutzer, während der Agent denkt oder spricht, wird sofort
// unterbrochen ("Barge-in"). "Mach weiter" setzt die unterbrochene Antwort fort,
// weil die bereits gesprochenen Sätze im Verlauf stehen.

import 'dart:async';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';

import 'app_controller.dart';
import 'voice_service.dart';

enum ConvState { off, listening, hearing, transcribing, thinking, speaking }

extension ConvStateLabel on ConvState {
  String get label => switch (this) {
        ConvState.off => 'Aus',
        ConvState.listening => 'Ich höre zu …',
        ConvState.hearing => 'Du sprichst …',
        ConvState.transcribing => 'Verstehe …',
        ConvState.thinking => 'Denke nach …',
        ConvState.speaking => 'Ich spreche – einfach reinreden zum Unterbrechen',
      };
}

class ConversationMode {
  ConversationMode(this.app);
  final AppController app;

  final state = ValueNotifier<ConvState>(ConvState.off);
  final userText = ValueNotifier<String>('');
  final agentText = ValueNotifier<String>('');
  final error = ValueNotifier<String?>(null);
  final muted = ValueNotifier<bool>(false);

  /// Zeiten der letzten Runde, z. B. „Aufnahme 3,2 s · Erkennung 1,4 s · erste Antwort 2,1 s“.
  final timing = ValueNotifier<String>('');

  /// Erkennt die Spracherkennung gerade Sprache? (Anzeige)
  final voiced = ValueNotifier<bool>(false);

  ValueNotifier<double> get level => app.voice.mic.level;

  final _vad = VoiceActivityDetector(endSilenceMs: 1200, maxUtteranceMs: 20000);
  SileroClassifier? _silero;

  /// Absender-Modus: Äußerung endet erst mit „Fertig“.
  final manualEnd = ValueNotifier<bool>(false);

  /// true, wenn der Silero-Sprachklassifikator aktiv ist.
  final smartVad = ValueNotifier<bool>(false);

  // Absender-Modus: alles seit Beginn der Runde wird aufgenommen (unabhängig von der Erkennung)
  final List<double> _manualBuf = [];
  bool _manualHeard = false;
  static const _manualMaxSamples = 16000 * 120;

  final _streamer = SentenceStreamer();
  int _turn = 0; // erhöht sich bei jeder neuen Runde/Unterbrechung
  bool _speakingStarted = false;
  Future<void>? _turnFuture;

  bool get active => state.value != ConvState.off;

  /// Einstellungen (Sprechpause, Absender-Modus, Nahfeld) übernehmen.
  void applySettings() {
    final st = app.settings;
    _vad
      ..endSilenceMs = st.voicePauseMs
      ..nearFieldDb = st.voiceNearField ? 15 : 0
      ..manual = false; // Absender-Modus nimmt selbst auf; VAD nur fürs Unterbrechen
    _vad.classifier = st.voiceSmartVad ? _silero?.call : null;
    smartVad.value = st.voiceSmartVad && _silero != null;
    manualEnd.value = st.voiceManualEnd;
  }

  String get _language => app.settings.sttLanguage == 'auto' ? 'de' : app.settings.sttLanguage;

  Future<void> start() async {
    if (active) return;
    error.value = null;
    timing.value = '';
    if (app.engine == null) throw Exception('Bitte zuerst ein Sprachmodell laden.');
    final stt = app.sttModelPath;
    if (stt == null) throw Exception('Für den Gesprächsmodus wird ein Whisper-Modell gebraucht (Systemcheck).');
    await app.voice.stopSpeaking();
    // Whisper vorab laden, damit die erste Antwort schnell kommt
    await app.voice.stt(stt);
    _silero = await app.voice.speechClassifier(Directory('${app.storage.root.path}/vad'));
    applySettings();
    _vad.reset();
    _silero?.reset();
    _manualBuf.clear();
    _manualHeard = false;
    // Gesprächs-Prompt vorrechnen → erste Antwort ohne Wartezeit
    unawaited(app.warmUp(voice: true));
    state.value = ConvState.listening;
    await app.voice.mic.start(_onFrame, echoCancel: true);
    voiceLog('Gespräch gestartet (Silero: ${smartVad.value}, Absender-Modus: ${manualEnd.value}, '
        'Pause: ${app.settings.voicePauseMs} ms, Sprache: $_language)');
  }

  Future<void> stop() async {
    _turn++;
    state.value = ConvState.off;
    await app.voice.mic.stop();
    app.voice.output.stop();
    if (app.running) app.stop();
    // Whisper freigeben – mehr Speicher fürs Sprachmodell
    unawaited(app.voice.releaseStt());
  }

  void toggleMute() => muted.value = !muted.value;

  /// Tippen auf den Kreis: Agent sofort unterbrechen.
  void interrupt() {
    if (state.value == ConvState.speaking || state.value == ConvState.thinking) {
      _bargeIn();
      _startListening();
    }
  }

  void _startListening() {
    _manualBuf.clear();
    _manualHeard = false;
    state.value = ConvState.listening;
  }

  /// Absender-Modus: „Ich bin fertig, antworte jetzt.“
  void finishSpeaking() {
    final s = state.value;
    if (s != ConvState.hearing && s != ConvState.listening) return;
    if (manualEnd.value) {
      if (_manualBuf.length < 16000 * 0.4) return;
      final pcm = Float32List.fromList(_manualBuf);
      _manualBuf.clear();
      _manualHeard = false;
      _vad.reset();
      unawaited(_handleUtterance(pcm));
      return;
    }
    if (_vad.finish()) {
      unawaited(_handleUtterance(_vad.takeUtterance()));
    } else {
      state.value = ConvState.listening;
    }
  }

  /// Aktuelle Aufnahme verwerfen.
  void discardSpeaking() {
    final s = state.value;
    if (s != ConvState.hearing && s != ConvState.listening) return;
    _vad.reset();
    _silero?.reset();
    _startListening();
  }

  void _onFrame(Float32List frame) {
    if (!active || muted.value) return;
    final s = state.value;
    // Während der Agent spricht, höhere Schwelle (Echo der eigenen Stimme)
    _vad.extraMarginDb = s == ConvState.speaking ? 12 : 0;
    final ev = _vad.add(frame);
    voiced.value = _vad.inSpeech;

    if (manualEnd.value) {
      // Absender-Modus: zuhören, bis „Fertig“ getippt wird
      if (ev == VadEvent.speechStart && (s == ConvState.speaking || s == ConvState.thinking)) {
        _bargeIn();
        _startListening();
      }
      if (state.value == ConvState.listening || state.value == ConvState.hearing) {
        _manualBuf.addAll(frame);
        if (_manualBuf.length > _manualMaxSamples) _manualBuf.removeRange(0, _manualBuf.length - _manualMaxSamples);
        if (ev == VadEvent.speechStart || _vad.inSpeech) _manualHeard = true;
        if (_manualHeard && state.value == ConvState.listening) state.value = ConvState.hearing;
      }
      if (ev == VadEvent.speechEnd) _vad.takeUtterance();
      return;
    }

    if (ev == VadEvent.speechStart) {
      if (s == ConvState.speaking || s == ConvState.thinking) _bargeIn();
      if (state.value != ConvState.transcribing) state.value = ConvState.hearing;
    } else if (ev == VadEvent.speechEnd) {
      final pcm = _vad.takeUtterance();
      unawaited(_handleUtterance(pcm));
    }
  }

  /// Agent verstummt und hört zu; bisher Gesprochenes bleibt im Verlauf.
  void _bargeIn() {
    _turn++;
    final spoken = _streamer.spokenSoFar;
    app.voice.output.stop();
    if (app.running) {
      app.stop();
    }
    if (_speakingStarted) unawaited(app.markLastAnswerInterrupted(spoken));
    _speakingStarted = false;
  }

  String _sec(int ms) => '${(ms / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';

  Future<void> _handleUtterance(Float32List pcm) async {
    // vorherige Runde sauber beenden lassen
    if (_turnFuture != null) {
      try {
        await _turnFuture!.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    final myTurn = ++_turn;
    state.value = ConvState.transcribing;
    final audioMs = pcm.length * 1000 ~/ 16000;
    timing.value = 'Aufnahme ${_sec(audioMs)} · erkenne …';
    final sw = Stopwatch()..start();
    String text;
    try {
      final stt = await app.voice.stt(app.sttModelPath!);
      text = (await stt.transcribe(pcm, language: _language, threads: app.device.threads)).text.trim();
    } catch (e) {
      error.value = 'Spracherkennung: $e';
      voiceLog('Spracherkennung fehlgeschlagen: $e');
      if (myTurn == _turn) _startListening();
      return;
    }
    final sttMs = sw.elapsedMilliseconds;
    timing.value = 'Aufnahme ${_sec(audioMs)} · Erkennung ${_sec(sttMs)}';
    voiceLog('Erkannt (${_sec(audioMs)} Audio in ${_sec(sttMs)}): "$text"');
    if (myTurn != _turn || !active) return;
    // Whisper halluziniert bei Stille gern solche Floskeln
    if (text.isEmpty || RegExp(r'^[\[(].*[\])]$').hasMatch(text) || _isFiller(text)) {
      error.value = text.isEmpty ? 'Nichts verstanden – bitte noch einmal.' : null;
      _startListening();
      return;
    }
    error.value = null;
    userText.value = text;
    agentText.value = '';
    state.value = ConvState.thinking;
    _turnFuture = _respond(text, myTurn, sttMs, audioMs);
    await _turnFuture;
  }

  Future<void> _respond(String text, int myTurn, int sttMs, int audioMs) async {
    // Läuft noch eine andere Antwort (z. B. aus dem Chat)? Erst beenden.
    if (app.running) {
      app.stop();
      for (var i = 0; i < 30 && app.running; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final out = app.voice.output
      ..voiceDir = app.ttsVoicePath
      ..language = _language == 'en' ? 'en' : 'de';
    out.begin();
    _streamer.reset();
    _speakingStarted = false;
    final sw = Stopwatch()..start();
    var firstMs = -1;
    await app.send(text, voice: true, onAnswer: (full, done) {
      if (myTurn != _turn) return;
      if (firstMs < 0 && full.trim().isNotEmpty) {
        firstMs = sw.elapsedMilliseconds;
        timing.value = 'Aufnahme ${_sec(audioMs)} · Erkennung ${_sec(sttMs)} · erste Worte nach ${_sec(firstMs)}';
      }
      agentText.value = full;
      for (final s in _streamer.feed(full, done: done)) {
        out.add(s);
        _speakingStarted = true;
        if (state.value == ConvState.thinking) state.value = ConvState.speaking;
      }
      if (done) out.finish();
    });
    voiceLog('Antwort: erste Worte nach ${firstMs < 0 ? '–' : _sec(firstMs)}, fertig nach ${_sec(sw.elapsedMilliseconds)}');
    if (myTurn != _turn) return;
    if (agentText.value.trim().isEmpty) {
      error.value = app.statusMessage ?? 'Keine Antwort erhalten – ist das Sprachmodell geladen?';
    }
    out.finish();
    await out.done;
    if (myTurn == _turn && active) {
      _speakingStarted = false;
      _startListening();
      final err = out.lastError.value;
      if (err != null) {
        error.value = err;
        out.lastError.value = null;
      }
    }
  }

  static bool _isFiller(String t) {
    final s = t.toLowerCase().replaceAll(RegExp(r'[^\p{L} ]', unicode: true), '').trim();
    return const {
      'untertitel im auftrag des zdf', 'untertitel im auftrag des zdf 2017', 'untertitel von stephanie geiges',
      'untertitel der amaraorg community', 'vielen dank', 'thanks for watching', 'thank you for watching', 'amen',
      'tschüss', 'bis zum nächsten mal',
    }.contains(s) && t.length < 40;
  }
}
