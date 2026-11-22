// Gesprächsmodus: freihändig sprechen wie mit einem Menschen.
//
//  zuhören → (Sprechpause oder „Fertig“) → Whisper → Agent → satzweise vorlesen → zuhören
//
// Spricht der Nutzer, während der Agent denkt oder spricht, wird sofort
// unterbrochen ("Barge-in"). "Mach weiter" setzt die unterbrochene Antwort fort,
// weil die bereits gesprochenen Sätze im Verlauf stehen.

import 'dart:async';
import 'dart:math' as math;
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
        ConvState.speaking => 'Ich spreche …',
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
  bool _sttSlow = false;
  int _turn = 0; // erhöht sich bei jeder neuen Runde/Unterbrechung
  bool _speakingStarted = false;
  Future<void>? _turnFuture;
  Timer? _watchdog;
  bool _restartingMic = false;

  /// Bis wann eine Folgefrage ohne Namen angenommen wird.
  DateTime _followUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _nameCheckBusy = false;

  /// Anzeige: Der Agent wartet auf seinen Namen.
  final needsName = ValueNotifier<bool>(false);

  bool get _wake => app.settings.voiceWakeWord;

  /// Reinreden unterbricht nur, wenn ausdrücklich eingeschaltet (sonst brechen Geräusche die Antwort ab).
  bool get _autoBargeIn => app.settings.voiceBargeIn && !_wake;
  String get agentName => app.settings.agentName;
  bool get _followOpen => DateTime.now().isBefore(_followUntil);

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
    // Fragt der Agent nach Internet, das ansagen – der Nutzer schaut evtl. nicht aufs Display
    app.onConsentAsk = null;
    app.voiceConsentHandler = _askConsentByVoice;
    // Gesprächs-Prompt vorrechnen und Stimme laden → erste Antwort ohne Wartezeit
    unawaited(app.warmUp(voice: true));
    app.voice.output
      ..voiceDir = app.ttsVoicePath
      ..systemVoice = app.settings.systemVoice
      ..slowSynth = 0
      ..language = _language == 'en' ? 'en' : 'de';
    unawaited(app.voice.output.warmUp());
    // Wer das Gespräch gerade geöffnet hat, meint den Agenten – erste Frage ohne Namen
    _followUntil = DateTime.now().add(const Duration(seconds: 30));
    needsName.value = false;
    state.value = ConvState.listening;
    await app.voice.mic.start(_onFrame, echoCancel: true);
    // Manche Android-Geräte beenden die Aufnahme, wenn die Sprachausgabe läuft → neu starten
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkMic());
    voiceLog('Gespräch gestartet (Silero: ${smartVad.value}, Absender-Modus: ${manualEnd.value}, '
        'Pause: ${app.settings.voicePauseMs} ms, Sprache: $_language)');
  }

  Future<void> _checkMic() async {
    if (!active || _restartingMic) return;
    final s = state.value;
    // Nicht während der Agent spricht: ein Neustart dort würde die Sprachausgabe stören
    if (s != ConvState.listening && s != ConvState.hearing) return;
    if (DateTime.now().difference(app.voice.mic.lastFrameAt).inMilliseconds < 2000) return;
    _restartingMic = true;
    voiceLog('Mikrofon liefert nichts mehr – starte neu');
    try {
      await app.voice.mic.start(_onFrame, echoCancel: true);
    } catch (e) {
      error.value = 'Mikrofon: $e';
    } finally {
      _restartingMic = false;
    }
  }

  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    app.onConsentAsk = null;
    app.voiceConsentHandler = null;
    answerConsent(NetworkChoice.deny);
    _turn++;
    state.value = ConvState.off;
    await app.voice.mic.stop();
    app.voice.output.stop();
    if (app.running) app.stop();
    // Whisper freigeben – mehr Speicher fürs Sprachmodell
    unawaited(app.voice.releaseStt());
  }

  void toggleMute() => muted.value = !muted.value;

  // ------------------------------------------------------------ Internet-Freigabe per Stimme

  /// Wofür der Agent gerade Internet möchte (Anzeige mit Knöpfen) – null = keine Frage offen.
  final consentPrompt = ValueNotifier<String?>(null);

  /// Überschrift der offenen Frage (Internet oder „Senden?“).
  final askTitle = ValueNotifier<String>('Internet erlauben? Sag „Ja“ oder „Nein“.');
  Completer<bool?>? _yesNo;

  /// Ja/Nein per Stimme oder Knopf; null = keine Antwort.
  Future<bool?> _askYesNo(String spoken, String title) async {
    final c = _yesNo = Completer<bool?>();
    askTitle.value = '$title Sag „Ja“ oder „Nein“.';
    consentPrompt.value = '';
    _consentSpokenUntil = DateTime.now().add(Duration(milliseconds: 600 + spoken.length * 75));
    final o = app.voice.output;
    o.begin();
    o.add(spoken);
    o.finish();
    state.value = ConvState.listening;
    final r = await c.future.timeout(const Duration(seconds: 30), onTimeout: () => null);
    _yesNo = null;
    consentPrompt.value = null;
    return r;
  }
  Completer<NetworkChoice>? _consent;
  DateTime _consentSpokenUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Future<NetworkChoice> _askConsentByVoice(String purpose) async {
    final c = _consent = Completer<NetworkChoice>();
    askTitle.value = 'Internet erlauben? Sag „Ja“ oder „Nein“.';
    consentPrompt.value = purpose;
    const msg = 'Dafür brauche ich das Internet. Darf ich? Sag ja oder nein.';
    // ungefähre Sprechdauer: so lange gilt Gehörtes als Echo der eigenen Frage
    _consentSpokenUntil = DateTime.now().add(Duration(milliseconds: 600 + msg.length * 75));
    app.voice.output.add(msg);
    voiceLog('Frage nach Internet: $purpose');
    final r = await c.future.timeout(const Duration(seconds: 45), onTimeout: () {
      voiceLog('Keine Antwort auf die Internet-Frage – abgelehnt');
      return NetworkChoice.deny;
    });
    _consent = null;
    consentPrompt.value = null;
    return r;
  }

  /// Antwort per Knopf (oder Stimme).
  void answerConsent(NetworkChoice choice) {
    final y = _yesNo;
    if (y != null && !y.isCompleted) {
      y.complete(choice != NetworkChoice.deny);
      return;
    }
    final c = _consent;
    if (c != null && !c.isCompleted) c.complete(choice);
  }

  Future<void> _consentFromSpeech(Float32List pcm) async {
    if (DateTime.now().isBefore(_consentSpokenUntil) || pcm.length < 16000 * 0.25) return;
    try {
      final stt = await app.voice.stt(app.sttModelPath!);
      final text = (await stt.transcribe(pcm, language: _language, threads: app.device.threads)).text.trim().toLowerCase();
      // eigenes Echo („Darf ich? Sag ja oder nein“) nicht als Antwort werten
      if (text.isEmpty || text.contains('darf ich') || text.contains('soll ich') || (text.contains(' ja') && text.contains('nein'))) return;
      final no = RegExp(r'\b(nein|nee|ne|nicht|lieber nicht|lass|stopp?|abbrechen|kein)\b').hasMatch(text);
      final yes = RegExp(r'\b(ja|jo|jep|jawohl|klar|gern|gerne|okay|ok|erlaub\w*|mach|darfst|passt|sicher|bitte)\b').hasMatch(text);
      voiceLog('Antwort auf Internet-Frage: "$text"');
      if (no) {
        answerConsent(NetworkChoice.deny);
      } else if (yes) {
        answerConsent(NetworkChoice.chat);
      }
    } catch (e) {
      voiceLog('Internet-Frage: Erkennung fehlgeschlagen: $e');
    }
  }

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
    needsName.value = _wake && !_followOpen;
    state.value = ConvState.listening;
  }

  /// Absender-Modus: „Ich bin fertig, antworte jetzt.“
  void finishSpeaking() {
    final s = state.value;
    if (s != ConvState.hearing && s != ConvState.listening) return;
    // Getippt = eindeutig an den Agenten gerichtet, Name nicht nötig
    _followUntil = DateTime.now().add(const Duration(seconds: 15));
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
      if (ev == VadEvent.speechStart && _autoBargeIn && (s == ConvState.speaking || s == ConvState.thinking)) {
        _bargeIn('Stimme erkannt');
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

    final busy = s == ConvState.speaking || s == ConvState.thinking;
    if (_consent != null || _yesNo != null) {
      // Frage offen (Internet / Senden): Gesprochenes ist die Antwort darauf
      if (ev == VadEvent.speechEnd) unawaited(_consentFromSpeech(_vad.takeUtterance()));
      return;
    }
    if (ev == VadEvent.speechStart) {
      // Mit Namens-Modus unterbrechen nur der Name oder ein Tipp – Geräusche nicht
      if (busy && _autoBargeIn) _bargeIn('Stimme erkannt');
      if (state.value != ConvState.transcribing && !(busy && !_autoBargeIn)) state.value = ConvState.hearing;
    } else if (ev == VadEvent.speechEnd) {
      final pcm = _vad.takeUtterance();
      if (busy && _wake) {
        unawaited(_checkInterruptByName(pcm));
      } else if (busy && !_autoBargeIn) {
        // Geräusch/Sprechen während der Antwort: ignorieren (unterbrechen nur per Tipp)
      } else {
        unawaited(_handleUtterance(pcm));
      }
    }
  }

  /// Agent verstummt und hört zu; bisher Gesprochenes bleibt im Verlauf.
  void _bargeIn([String reason = 'Tipp']) {
    if (state.value == ConvState.speaking || state.value == ConvState.thinking) voiceLog('Antwort unterbrochen: $reason');
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
    _sttSlow = sttMs > 3000;
    if (myTurn != _turn || !active) return;
    // Whisper halluziniert bei Stille gern solche Floskeln
    if (text.isEmpty || RegExp(r'^[\[(].*[\])]$').hasMatch(text) || _isFiller(text)) {
      error.value = text.isEmpty ? 'Nichts verstanden – bitte noch einmal.' : null;
      _startListening();
      return;
    }
    text = collapseRepeats(text)
        // „Regenbogen ? ? ?“ → „Regenbogen?“
        .replaceAllMapped(RegExp(r'\s*([?!.])(?:\s*[?!.])+'), (m) => m.group(1)!)
        .replaceAllMapped(RegExp(r'\s+([?!.,])'), (m) => m.group(1)!);
    if (_wake) {
      final rest = stripWakeName(text, agentName);
      if (rest == null && !_followOpen) {
        voiceLog('Ohne „$agentName“ – ignoriert: "$text"');
        // sichtbar machen, warum nichts passiert
        error.value = 'Gehört: „$text“ – sag „$agentName, …“ davor oder tipp auf den Kreis';
        _startListening();
        return;
      }
      if (rest != null && rest.isEmpty) {
        // Nur der Name: zuhören, die Frage kommt gleich
        _followUntil = DateTime.now().add(const Duration(seconds: 12));
        userText.value = '$agentName …';
        _startListening();
        return;
      }
      if (rest != null) text = rest;
    }
    await _startTurn(text, myTurn, sttMs, audioMs);
  }

  Future<void> _startTurn(String text, int myTurn, int sttMs, int audioMs) async {
    error.value = null;
    needsName.value = false;
    userText.value = text;
    agentText.value = '';
    state.value = ConvState.thinking;
    _turnFuture = _respond(text, myTurn, sttMs, audioMs);
    await _turnFuture;
  }

  /// Namens-Modus: Während der Agent spricht, unterbricht nur der Name („Junels, stopp“).
  Future<void> _checkInterruptByName(Float32List pcm) async {
    if (_nameCheckBusy || pcm.length < 16000 * 0.3) return;
    _nameCheckBusy = true;
    try {
      final sw = Stopwatch()..start();
      final stt = await app.voice.stt(app.sttModelPath!);
      final text = collapseRepeats((await stt.transcribe(pcm, language: _language, threads: app.device.threads)).text.trim());
      final rest = stripWakeName(text, agentName);
      final s = state.value;
      if (rest == null || (s != ConvState.speaking && s != ConvState.thinking)) {
        if (text.isNotEmpty) voiceLog('Während der Antwort gehört, ohne Namen – weiter: "$text"');
        return;
      }
      _bargeIn('„$agentName“ gehört: "$text"');
      if (rest.isEmpty || RegExp(r'^(stopp?|halt|ruhe|still|warte|danke)\W*$', caseSensitive: false).hasMatch(rest)) {
        _followUntil = DateTime.now().add(const Duration(seconds: 12));
        _startListening();
        return;
      }
      await _startTurn(rest, ++_turn, sw.elapsedMilliseconds, pcm.length * 1000 ~/ 16000);
    } catch (e) {
      voiceLog('Namensprüfung fehlgeschlagen: $e');
    } finally {
      _nameCheckBusy = false;
    }
  }

  static String _normName(String s) => s
      .toLowerCase()
      .replaceAll('ä', 'ae')
      .replaceAll('ö', 'oe')
      .replaceAll('ü', 'ue')
      .replaceAll('ß', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  static int _lev(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)].reduce(math.min);
      }
      prev = cur;
    }
    return prev[b.length];
  }

  static bool _nameLike(String w, String n) {
    if (w.isEmpty) return false;
    if (w == n || w.startsWith(n)) return true;
    if (n.length >= 4 && w.length >= 3 && _lev(w, n) <= (n.length >= 6 ? 2 : 1)) return true;
    return false;
  }

  /// Text ohne den Namen (und „hey“, „hallo“ davor) – oder null, wenn der Name nicht vorkommt.
  static String? stripWakeName(String text, String name) {
    final n = _normName(name);
    if (n.isEmpty) return text;
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final nameWords = name.trim().split(RegExp(r'\s+')).length;
    for (var i = 0; i < words.length; i++) {
      final end = math.min(words.length, i + nameWords);
      final cand = _normName(words.sublist(i, end).join());
      if (!_nameLike(cand, n)) continue;
      var start = i;
      while (start > 0 && RegExp(r'^(hey|hei|hallo|hi|ok|okay|he|oh|du|liebe[rs]?)$').hasMatch(_normName(words[start - 1]))) {
        start--;
      }
      final rest = [...words.sublist(0, start), ...words.sublist(end)].join(' ');
      return rest.replaceFirst(RegExp(r'^[\s,.!?:;–-]+'), '').trim();
    }
    return null;
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
      ..systemVoice = app.settings.systemVoice
      ..language = _language == 'en' ? 'en' : 'de';
    out.begin();
    _streamer.reset();
    _speakingStarted = false;
    final sw = Stopwatch()..start();
    var firstMs = -1;
    var saidWait = false;
    await app.send(text, voice: true, onToolStart: (tool) {
      // Werkzeuge (Internet) brauchen Zeit: kurz Bescheid geben statt stumm zu warten
      if (myTurn != _turn || _speakingStarted || saidWait) return;
      saidWait = true;
      out.add(switch (tool) {
        'weather' => 'Moment, ich schaue mir das Wetter an.',
        'news' => 'Moment, ich hole die Nachrichten.',
        'calculator' => 'Einen Moment.',
        _ => 'Moment, ich schaue nach.',
      });
      if (state.value == ConvState.thinking) state.value = ConvState.speaking;
    }, onAnswer: (raw, done) {
      if (myTurn != _turn) return;
      // Wiederholte Frage und lautes Denken nicht vorlesen
      final full = stripAnswerPreamble(raw, text, done: done);
      if (full == null) return;
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
    final tips = <String>[
      if (_sttSlow) 'Spracherkennung langsam → im Systemcheck „Canary“ laden (viel schneller)',
      if (firstMs > 6000) 'Antwort langsam → kleineres Sprachmodell (z. B. Gemma 4 E2B)',
      if (out.slowSynth > 0 && out.voiceDir != null)
        'Pausen: die Stimme ist auf diesem Gerät langsamer als Echtzeit → Einstellungen → Sprache → „Stimme des Geräts“ oder Piper',
    ];
    if (tips.isNotEmpty) timing.value = '${timing.value}\nTipp: ${tips.join(' · ')}';
    if (myTurn != _turn) return;
    if (agentText.value.trim().isEmpty) {
      error.value = app.statusMessage ?? 'Keine Antwort erhalten – ist das Sprachmodell geladen?';
    }
    out.finish();
    // Hängt die Sprachausgabe, trotzdem wieder zuhören
    await out.done.timeout(const Duration(minutes: 3), onTimeout: () => out.stop());
    // Entwurf (E-Mail, WhatsApp) wartet auf Freigabe → per Stimme fragen
    final pa = app.pendingAction;
    if (pa != null && myTurn == _turn && active) {
      final yes = await _askYesNo('Soll ich das senden? Sag ja oder nein.', 'Senden?');
      if (myTurn == _turn && active) {
        final o = app.voice.output..begin();
        if (yes == true) {
          final msg = await app.runAction(pa.$1, pa.$2, approval: 'Du hast im Gespräch „Ja“ gesagt');
          o.add('$msg.');
        } else if (yes == false) {
          o.add('Okay, nicht gesendet. Der Entwurf bleibt im Chat.');
        }
        o.finish();
        await o.done.timeout(const Duration(seconds: 30), onTimeout: () => o.stop());
      }
    }
    // Kurz danach geht eine Folgefrage auch ohne Namen
    _followUntil = DateTime.now().add(const Duration(seconds: 20));
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

  /// Whisper wiederholt manchmal denselben Satz – Wiederholungen entfernen.
  static String collapseRepeats(String t) {
    final parts = RegExp(r'[^.!?]+[.!?]*').allMatches(t).map((m) => m.group(0)!.trim()).where((p) => p.isNotEmpty).toList();
    final out = <String>[];
    for (final p in parts) {
      final k = p.toLowerCase().replaceAll(RegExp(r'[^\p{L}\d]', unicode: true), '');
      if (out.any((o) => o.toLowerCase().replaceAll(RegExp(r'[^\p{L}\d]', unicode: true), '') == k)) continue;
      out.add(p);
    }
    return out.join(' ');
  }

  static bool _isFiller(String t) {
    final s = t.toLowerCase().replaceAll(RegExp(r'[^\p{L} ]', unicode: true), '').trim();
    return const {
      'untertitel im auftrag des zdf', 'untertitel im auftrag des zdf 2017', 'untertitel von stephanie geiges',
      'untertitel der amaraorg community', 'vielen dank', 'thanks for watching', 'thank you for watching', 'amen',
      'tschüss', 'bis zum nächsten mal', 'bitte', 'danke', 'danke schön', 'dankeschön', 'hm', 'äh',
    }.contains(s) && t.length < 40;
  }
}
