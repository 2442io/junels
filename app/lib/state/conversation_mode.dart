// Gesprächsmodus: freihändig sprechen wie mit einem Menschen.
//
//  zuhören → (Sprechpause erkannt) → Whisper → Agent → satzweise vorlesen → zuhören
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

  ValueNotifier<double> get level => app.voice.mic.level;

  final _vad = VoiceActivityDetector(endSilenceMs: 1200);
  SileroClassifier? _silero;

  /// Absender-Modus: Äußerung endet erst mit „Fertig“.
  final manualEnd = ValueNotifier<bool>(false);

  /// true, wenn der Silero-Sprachklassifikator aktiv ist.
  final smartVad = ValueNotifier<bool>(false);

  /// Einstellungen (Sprechpause, Absender-Modus, Nahfeld) übernehmen.
  void applySettings() {
    final st = app.settings;
    _vad
      ..endSilenceMs = st.voicePauseMs
      ..nearFieldDb = st.voiceNearField ? 15 : 0
      ..manual = st.voiceManualEnd;
    manualEnd.value = st.voiceManualEnd;
  }

  /// Absender-Modus: „Ich bin fertig, antworte jetzt.“
  void finishSpeaking() {
    if (state.value != ConvState.hearing) return;
    if (_vad.finish()) {
      unawaited(_handleUtterance(_vad.takeUtterance()));
    } else {
      state.value = ConvState.listening;
    }
  }

  /// Aktuelle Aufnahme verwerfen (Absender-Modus).
  void discardSpeaking() {
    if (state.value != ConvState.hearing) return;
    _vad.reset();
    _silero?.reset();
    state.value = ConvState.listening;
  }
  final _streamer = SentenceStreamer();
  int _turn = 0; // erhöht sich bei jeder neuen Runde/Unterbrechung
  bool _speakingStarted = false;
  Future<void>? _turnFuture;

  bool get active => state.value != ConvState.off;

  Future<void> start() async {
    if (active) return;
    error.value = null;
    if (app.engine == null) throw Exception('Bitte zuerst ein Sprachmodell laden.');
    final stt = app.sttModelPath;
    if (stt == null) throw Exception('Für den Gesprächsmodus wird ein Whisper-Modell gebraucht (Systemcheck).');
    await app.voice.stopSpeaking();
    // Whisper vorab laden, damit die erste Antwort schnell kommt
    await app.voice.stt(stt);
    _silero = await app.voice.speechClassifier(Directory('${app.storage.root.path}/vad'));
    _vad.classifier = _silero?.call;
    smartVad.value = _silero != null;
    applySettings();
    _vad.reset();
    _silero?.reset();
    state.value = ConvState.listening;
    await app.voice.mic.start(_onFrame, echoCancel: true);
  }

  Future<void> stop() async {
    _turn++;
    state.value = ConvState.off;
    await app.voice.mic.stop();
    app.voice.output.stop();
    if (app.running) app.stop();
  }

  void toggleMute() => muted.value = !muted.value;

  /// Tippen auf den Kreis: Agent sofort unterbrechen.
  void interrupt() {
    if (state.value == ConvState.speaking || state.value == ConvState.thinking) {
      _bargeIn();
      state.value = ConvState.listening;
    }
  }

  void _onFrame(Float32List frame) {
    if (!active || muted.value) return;
    final s = state.value;
    // Während der Agent spricht, höhere Schwelle (Echo der eigenen Stimme)
    _vad.extraMarginDb = s == ConvState.speaking ? 12 : 0;
    final ev = _vad.add(frame);
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

  Future<void> _handleUtterance(Float32List pcm) async {
    // vorherige Runde sauber beenden lassen
    if (_turnFuture != null) {
      try {
        await _turnFuture!.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    final myTurn = ++_turn;
    state.value = ConvState.transcribing;
    String text;
    try {
      final stt = await app.voice.stt(app.sttModelPath!);
      text = (await stt.transcribe(pcm, language: app.settings.sttLanguage, threads: app.device.threads)).text.trim();
    } catch (e) {
      error.value = 'Spracherkennung: $e';
      if (myTurn == _turn) state.value = ConvState.listening;
      return;
    }
    if (myTurn != _turn || !active) return;
    // Whisper halluziniert bei Stille gern solche Floskeln
    if (text.isEmpty || RegExp(r'^[\[(].*[\])]$').hasMatch(text) || _isFiller(text)) {
      state.value = ConvState.listening;
      return;
    }
    userText.value = text;
    agentText.value = '';
    state.value = ConvState.thinking;
    _turnFuture = _respond(text, myTurn);
    await _turnFuture;
  }

  Future<void> _respond(String text, int myTurn) async {
    final out = app.voice.output
      ..voiceDir = app.ttsVoicePath
      ..language = app.settings.sttLanguage == 'en' ? 'en' : 'de';
    out.begin();
    _streamer.reset();
    _speakingStarted = false;
    await app.send(text, voice: true, onAnswer: (full, done) {
      if (myTurn != _turn) return;
      agentText.value = full;
      for (final s in _streamer.feed(full, done: done)) {
        out.add(s);
        _speakingStarted = true;
        if (state.value == ConvState.thinking) state.value = ConvState.speaking;
      }
      if (done) out.finish();
    });
    if (myTurn != _turn) return;
    out.finish();
    await out.done;
    if (myTurn == _turn && active) {
      _speakingStarted = false;
      state.value = ConvState.listening;
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
      'thanks for watching', 'thank you for watching', 'amen',
    }.contains(s) && t.length < 40;
  }
}
