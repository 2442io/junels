// Mitschrift: Gespräch/Besprechung laufend mitschreiben (Whisper, auf dem Gerät).
// Danach: neuer Chat mit der Mitschrift – Zusammenfassung, Rückfragen, auf Wunsch als Word.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import 'app_controller.dart';
import 'conversation_mode.dart' show ConversationMode;
import 'voice_service.dart' show appLog;

class TranscriptLine {
  TranscriptLine(this.at, this.text);
  final Duration at;
  String text;
}

class MeetingTranscriber extends ChangeNotifier {
  MeetingTranscriber(this.app);
  final AppController app;

  final lines = <TranscriptLine>[];
  bool active = false;
  bool paused = false;
  bool busy = false; // transkribiert gerade einen Abschnitt
  String? error;
  DateTime? _start;
  Duration _pausedFor = Duration.zero;
  DateTime? _pausedAt;
  Timer? _tick;

  // Abschnitte: kurze Pausen beenden einen Abschnitt, höchstens 25 s am Stück
  final _vad = VoiceActivityDetector(endSilenceMs: 800, maxUtteranceMs: 25000, preRollMs: 600);
  final _queue = <(Duration, Float32List)>[];
  Future<void>? _worker;

  Duration get elapsed {
    final s = _start;
    if (s == null) return Duration.zero;
    final end = _pausedAt ?? DateTime.now();
    return end.difference(s) - _pausedFor;
  }

  int get words => lines.fold(0, (n, l) => n + l.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length);

  String get _language => app.settings.sttLanguage == 'auto' ? 'de' : app.settings.sttLanguage;

  Future<void> start() async {
    if (active) return;
    error = null;
    final model = app.sttModelPath;
    if (model == null) {
      error = 'Für die Mitschrift wird ein Whisper-Modell gebraucht (Einstellungen → Systemcheck → Sprache).';
      notifyListeners();
      return;
    }
    try {
      await app.voice.stopSpeaking();
      await app.voice.stt(model);
      final silero = await app.voice.speechClassifier(Directory('${app.storage.root.path}/vad'));
      _vad
        ..classifier = silero?.call
        ..reset();
      silero?.reset();
      lines.clear();
      _queue.clear();
      _start = DateTime.now();
      _pausedFor = Duration.zero;
      _pausedAt = null;
      paused = false;
      active = true;
      await app.voice.mic.start(_onFrame);
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
      appLog('Mitschrift', 'gestartet');
    } catch (e) {
      active = false;
      error = '$e';
    }
    notifyListeners();
  }

  void _onFrame(Float32List frame) {
    if (!active || paused) return;
    final ev = _vad.add(frame);
    if (ev == VadEvent.speechEnd) {
      final pcm = _vad.takeUtterance();
      // Anfang des Abschnitts (ungefähr): jetzt minus Länge
      final at = elapsed - Duration(milliseconds: pcm.length * 1000 ~/ 16000);
      _queue.add((at.isNegative ? Duration.zero : at, pcm));
      _worker ??= _work().whenComplete(() => _worker = null);
    }
  }

  Future<void> _work() async {
    while (_queue.isNotEmpty) {
      final (at, pcm) = _queue.removeAt(0);
      if (pcm.length < 16000 * 0.4) continue; // zu kurz (Knacken, Räuspern)
      busy = true;
      notifyListeners();
      try {
        final stt = await app.voice.stt(app.sttModelPath!);
        // kurze Stille davor: Whisper verschluckt sonst gern das erste Wort
        final padded = Float32List(pcm.length + 4000 + 3200)..setRange(4000, 4000 + pcm.length, pcm);
        final text = ConversationMode.collapseRepeats((await stt.transcribe(padded, language: _language, threads: app.device.threads)).text.trim());
        if (text.isNotEmpty && !RegExp(r'^[\[(].*[\])]$').hasMatch(text)) lines.add(TranscriptLine(at, text));
      } catch (e) {
        appLog('Mitschrift', 'Erkennung: $e', error: true);
      }
      busy = false;
      notifyListeners();
    }
  }

  void togglePause() {
    if (!active) return;
    paused = !paused;
    if (paused) {
      _pausedAt = DateTime.now();
      _vad.reset();
    } else if (_pausedAt != null) {
      _pausedFor += DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
    }
    notifyListeners();
  }

  /// Aufnahme beenden, letzte Abschnitte fertig erkennen
  Future<void> stop() async {
    if (!active) return;
    active = false;
    _tick?.cancel();
    try {
      await app.voice.mic.stop();
    } catch (_) {}
    // Rest im Puffer (wenn mitten im Sprechen beendet)
    final rest = _vad.takeUtterance();
    if (rest.isNotEmpty) _queue.add((elapsed, rest));
    if (_queue.isNotEmpty) _worker ??= _work().whenComplete(() => _worker = null);
    await _worker;
    _pausedAt ??= DateTime.now();
    notifyListeners();
  }

  void discard() {
    if (active) unawaited(stop());
    lines.clear();
    _start = null;
    notifyListeners();
  }

  static String stamp(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  String get text => lines.map((l) => '[${stamp(l.at)}] ${l.text}').join('\n');

  /// Mitschrift in einen neuen Chat: Datei + Text, danach fasst der Agent zusammen und stellt Rückfragen.
  Future<Conversation?> toChat({String title = ''}) async {
    if (lines.isEmpty) return null;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = title.trim().isNotEmpty ? title.trim() : 'Mitschrift ${now.day}.${now.month}. ${two(now.hour)}:${two(now.minute)}';
    final dir = app.outputsDir..createSync(recursive: true);
    final file = File('${dir.path}/${name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')}.txt');
    await file.writeAsString('$name\nDauer: ${stamp(elapsed)} · ${lines.length} Abschnitte · $words Wörter\n\n$text\n');
    final c = Conversation(id: newId(), title: name, icon: 'post', color: 'blau');
    c.entries.add(ChatEntry(
      role: 'assistant',
      skill: 'Mitschrift',
      text: '📝 **$name** · ${stamp(elapsed)} · $words Wörter\n\n$text',
      files: [file.path],
    ));
    app.conversations.insert(0, c);
    app.current = c;
    await app.storage.saveConversation(c);
    app.refreshUi();
    lines.clear();
    _start = null;
    notifyListeners();
    // Gleich auswerten: Zusammenfassung + Rückfragen; Word auf Wunsch
    unawaited(app.send('Werte die Mitschrift oben aus: kurze Zusammenfassung (Thema, Teilnehmende wenn erkennbar, wichtigste Punkte, '
        'Entscheidungen, Aufgaben mit Zuständigen und Fristen). Stelle mir danach bis zu 3 Rückfragen zu Unklarem '
        '(z. B. wer etwas übernimmt, Namen, Termine). Biete am Ende an, alles als Word-Dokument abzulegen.'));
    return c;
  }
}
