// Mitschrift: Gespräch/Besprechung laufend mitschreiben (Whisper, auf dem Gerät).
// Sprecher werden am Stimm-Fingerabdruck unterschieden, Musik und Geräusche erkannt;
// die Aufnahme wird als WAV gesichert. Danach: neuer Chat mit Zusammenfassung und Rückfragen.

import '../l10n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/foundation.dart';

import '../data/models.dart';
import 'app_controller.dart';
import 'conversation_mode.dart' show ConversationMode;
import 'meeting_audio.dart';
import 'voice_service.dart' show appLog;

/// Ein Abschnitt der Mitschrift: Sprache (mit Sprecher), Musik oder Geräusch.
class TranscriptLine {
  TranscriptLine(this.at, this.text, {this.end, this.speaker = -1, this.kind = 'speech', this.label = ''});
  Duration at;
  Duration? end;
  String text;
  int speaker; // -1 = unbekannt
  String kind; // speech | music | sound
  String label; // z. B. „Musik“, „Applaus“

  Map<String, dynamic> toJson() => {
        'at': at.inMilliseconds,
        if (end != null) 'end': end!.inMilliseconds,
        'text': text,
        'speaker': speaker,
        if (kind != 'speech') 'kind': kind,
        if (label.isNotEmpty) 'label': label,
      };

  factory TranscriptLine.fromJson(Map<String, dynamic> j) => TranscriptLine(
        Duration(milliseconds: (j['at'] as num?)?.toInt() ?? 0),
        j['text'] as String? ?? '',
        end: j['end'] == null ? null : Duration(milliseconds: (j['end'] as num).toInt()),
        speaker: (j['speaker'] as num?)?.toInt() ?? -1,
        kind: j['kind'] as String? ?? 'speech',
        label: j['label'] as String? ?? '',
      );
}

/// Gespeicherte Mitschrift (…mitschrift.json): Abschnitte, Sprechernamen, Aufnahme.
class MeetingTranscript {
  MeetingTranscript({required this.title, required this.lines, required this.speakers, this.audio, this.duration = Duration.zero, this.file});
  String title;
  final List<TranscriptLine> lines;
  final List<String> speakers;
  String? audio;
  Duration duration;
  File? file;

  String speakerName(int i) => i >= 0 && i < speakers.length ? speakers[i] : 'Unbekannt';

  int get words => lines.where((l) => l.kind == 'speech').fold(0, (n, l) => n + l.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length);

  /// Sprecher, die wirklich vorkommen
  List<int> get usedSpeakers => {for (final l in lines) if (l.kind == 'speech' && l.speaker >= 0) l.speaker}.toList()..sort();

  /// Lesbar wie ein Interview-Transkript; aufeinanderfolgende Abschnitte desselben Sprechers zusammen.
  String interview({bool markdown = false}) {
    final b = StringBuffer();
    var last = -2;
    for (final l in lines) {
      final ts = MeetingTranscriber.stamp(l.at);
      if (l.kind != 'speech') {
        final what = l.label.isNotEmpty ? l.label : (l.kind == 'music' ? 'Musik' : 'Geräusch');
        b.write('${b.isEmpty ? '' : '\n\n'}[$ts] ${l.kind == 'music' ? '♪ ' : ''}$what${l.text.isNotEmpty ? ': „${l.text}“' : ''}');
        last = -2;
        continue;
      }
      final multi = usedSpeakers.length > 1 || speakers.isNotEmpty && l.speaker >= 0;
      if (l.speaker == last && multi) {
        b.write(' ${l.text}');
        continue;
      }
      final who = multi ? (markdown ? '**${speakerName(l.speaker)}**' : speakerName(l.speaker)) : '';
      b.write('${b.isEmpty ? '' : '\n\n'}[$ts] ${who.isNotEmpty ? '$who: ' : ''}${l.text}');
      last = l.speaker;
    }
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'duration': duration.inMilliseconds,
        if (audio != null) 'audio': audio,
        'speakers': speakers,
        'lines': [for (final l in lines) l.toJson()],
      };

  static MeetingTranscript? load(String path) {
    try {
      final f = File(path);
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return MeetingTranscript(
        title: j['title'] as String? ?? 'Mitschrift',
        duration: Duration(milliseconds: (j['duration'] as num?)?.toInt() ?? 0),
        audio: j['audio'] as String?,
        speakers: [for (final s in (j['speakers'] as List? ?? const [])) '$s'],
        lines: [for (final l in (j['lines'] as List? ?? const [])) TranscriptLine.fromJson((l as Map).cast())],
        file: f,
      );
    } catch (_) {
      return null;
    }
  }

  /// JSON und Text-Fassung (gleicher Name, .txt) speichern
  Future<void> save() async {
    final f = file;
    if (f == null) return;
    await f.writeAsString(const JsonEncoder.withIndent(' ').convert(toJson()));
    final txt = File(f.path.replaceFirst(RegExp(r'\.mitschrift\.json$'), '.txt'));
    await txt.writeAsString('$title\nDauer: ${MeetingTranscriber.stamp(duration)} · $words Wörter'
        '${usedSpeakers.length > 1 ? ' · Sprecher: ${usedSpeakers.map(speakerName).join(', ')}' : ''}\n\n${interview()}\n');
  }
}

class MeetingTranscriber extends ChangeNotifier {
  MeetingTranscriber(this.app);
  final AppController app;

  final lines = <TranscriptLine>[];
  final speakers = <String>[]; // Namen (Index = Sprecher-Nummer)
  bool active = false;
  bool paused = false;
  bool busy = false; // transkribiert gerade einen Abschnitt
  String? error;
  DateTime? _start;
  Duration _pausedFor = Duration.zero;
  DateTime? _pausedAt;
  Timer? _tick;

  // Abschnitte: kurze Pausen beenden einen Abschnitt (Sprecherwechsel), höchstens 20 s am Stück
  final _vad = VoiceActivityDetector(endSilenceMs: 650, maxUtteranceMs: 20000, preRollMs: 500);
  final _queue = <(Duration, Float32List, bool)>[]; // (Beginn, Ton, Hintergrund?)
  Future<void>? _worker;

  // Sprecher, Musik/Geräusche, Aufnahme
  late final models = MeetingModels(Directory('${app.storage.voiceDir.path}/mitschrift'));
  final _speakers = SpeakerTracker();
  WavWriter? _wav;
  File? _audioFile;
  bool keepAudio = true;

  // Hintergrund: laute Stellen ohne Sprache (Musik, Applaus …)
  final _bg = <Float32List>[];
  int _bgSamples = 0;
  double _floorDb = -60;

  // Laden der Zusatzmodelle
  double? downloadProgress;
  String downloadWhat = '';
  CancelToken? _cancel;

  bool get diarization => models.ready;

  Duration get elapsed {
    final s = _start;
    if (s == null) return Duration.zero;
    final end = _pausedAt ?? DateTime.now();
    return end.difference(s) - _pausedFor;
  }

  /// Position in der Aufnahme (passt genau zur WAV-Datei)
  Duration get _audioPos => _wav != null ? Duration(milliseconds: _wav!.samples * 1000 ~/ 16000) : elapsed;

  int get words => doc.words;

  MeetingTranscript get doc => MeetingTranscript(title: '', lines: lines, speakers: speakers, duration: elapsed);

  String _language() => app.settings.sttLanguage == 'auto' ? appLang : app.settings.sttLanguage;

  Future<void> downloadModels() async {
    if (downloadProgress != null) return;
    downloadProgress = 0;
    downloadWhat = 'Starte …';
    _cancel = CancelToken();
    notifyListeners();
    try {
      await models.download(
        downloader: Downloader(),
        extract: app.extractArchive,
        cancel: _cancel,
        onProgress: (p, w) {
          downloadProgress = p;
          downloadWhat = w;
          notifyListeners();
        },
      );
      models.load(threads: math.max(1, app.device.threads ~/ 2));
    } catch (e) {
      error = 'Laden fehlgeschlagen: $e';
    }
    downloadProgress = null;
    notifyListeners();
  }

  void cancelDownload() => _cancel?.cancel();

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
      models.load(threads: math.max(1, app.device.threads ~/ 2));
      lines.clear();
      speakers.clear();
      _speakers.reset();
      _queue.clear();
      _bg.clear();
      _bgSamples = 0;
      _floorDb = -60;
      if (keepAudio) {
        final tmp = Directory('${app.storage.root.path}/tmp')..createSync(recursive: true);
        _audioFile = File('${tmp.path}/mitschrift-${DateTime.now().millisecondsSinceEpoch}.wav');
        _wav = WavWriter(_audioFile!)..open();
      }
      _start = DateTime.now();
      _pausedFor = Duration.zero;
      _pausedAt = null;
      paused = false;
      active = true;
      await app.voice.mic.start(_onFrame);
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
      appLog('Mitschrift', 'gestartet${models.ready ? ' (mit Sprechererkennung)' : ''}');
    } catch (e) {
      active = false;
      error = '$e';
    }
    notifyListeners();
  }

  void _onFrame(Float32List frame) {
    if (!active || paused) return;
    _wav?.add(frame);
    final ev = _vad.add(frame);
    if (ev == VadEvent.speechStart) _flushBackground();
    if (ev == VadEvent.speechEnd) {
      final pcm = _vad.takeUtterance();
      final at = _audioPos - Duration(milliseconds: pcm.length * 1000 ~/ 16000);
      _enqueue(at.isNegative ? Duration.zero : at, pcm, false);
    }
    // Hintergrund: laut, aber keine Sprache → sammeln (Musik, Applaus …)
    if (models.ready && !_vad.inSpeech) {
      var e = 0.0;
      for (final x in frame) {
        e += x * x;
      }
      final db = 10 * math.log(e / frame.length + 1e-10) / math.ln10;
      _floorDb = db < _floorDb ? db : _floorDb * 0.999 + db * 0.001;
      if (db > -45 && db > _floorDb + 14) {
        _bg.add(Float32List.fromList(frame));
        _bgSamples += frame.length;
        if (_bgSamples >= 16000 * 12) _flushBackground();
      } else if (_bgSamples > 0 && db < _floorDb + 6) {
        _flushBackground();
      }
    }
  }

  void _flushBackground() {
    if (_bgSamples >= 16000 * 2.5) {
      final pcm = Float32List(_bgSamples);
      var o = 0;
      for (final f in _bg) {
        pcm.setRange(o, o + f.length, f);
        o += f.length;
      }
      final at = _audioPos - Duration(milliseconds: _bgSamples * 1000 ~/ 16000);
      _enqueue(at.isNegative ? Duration.zero : at, pcm, true);
    }
    _bg.clear();
    _bgSamples = 0;
  }

  void _enqueue(Duration at, Float32List pcm, bool background) {
    _queue.add((at, pcm, background));
    _worker ??= _work().whenComplete(() => _worker = null);
  }

  int get _lastSpeaker => lines.lastWhere((l) => l.kind == 'speech', orElse: () => TranscriptLine(Duration.zero, '')).speaker;

  /// Musik/Geräusch anhängen; gleiche Art direkt davor wird verlängert
  void _addEvent(Duration at, Duration end, String kind, String label, String text) {
    final last = lines.isEmpty ? null : lines.last;
    if (last != null && last.kind == kind && last.label == label && at - (last.end ?? last.at) < const Duration(seconds: 20)) {
      last.end = end;
      if (text.isNotEmpty) last.text = last.text.isEmpty ? text : '${last.text} $text';
      return;
    }
    lines.add(TranscriptLine(at, text, end: end, kind: kind, label: label));
  }

  Future<void> _work() async {
    while (_queue.isNotEmpty) {
      final (at, pcm, background) = _queue.removeAt(0);
      final secs = pcm.length / 16000;
      final end = at + Duration(milliseconds: (secs * 1000).round());
      busy = true;
      notifyListeners();
      try {
        if (background) {
          final kind = soundKind(models.tag(pcm));
          if (kind != null) _addEvent(at, end, kind.$1, kind.$2, '');
        } else if (secs >= 0.4) {
          final sound = models.ready ? soundKind(models.tag(pcm)) : null;
          final stt = await app.voice.stt(app.sttModelPath!);
          // kurze Stille davor: Whisper verschluckt sonst gern das erste Wort
          final padded = Float32List(pcm.length + 4000 + 3200)..setRange(4000, 4000 + pcm.length, pcm);
          var text = ConversationMode.collapseRepeats((await stt.transcribe(padded, language: _language(), threads: app.device.threads)).text.trim());
          final marker = whisperMarker(text);
          if (marker?.$1 == 'skip') {
            text = '';
          } else if (marker != null) {
            _addEvent(at, end, marker.$1, marker.$2, '');
            text = '';
          }
          if (sound != null && sound.$1 == 'music') {
            // Musik (ggf. mit Gesang): Text als Liedzeile, nicht als Wortmeldung
            _addEvent(at, end, 'music', sound.$2, text.replaceAll(RegExp(r'[♪*]'), '').trim());
          } else if (text.isNotEmpty) {
            var who = -1;
            final emb = models.ready ? models.embed(pcm) : null;
            if (emb != null) {
              who = _speakers.assign(emb, seconds: secs, previous: _lastSpeaker);
              while (speakers.length <= who) {
                speakers.add('Sprecher ${speakers.length + 1}');
              }
            }
            lines.add(TranscriptLine(at, text, end: end, speaker: who));
            if (sound != null && sound.$1 == 'sound') _addEvent(at, end, 'sound', sound.$2, '');
          }
        }
      } catch (e) {
        appLog('Mitschrift', 'Erkennung: $e', error: true);
      }
      busy = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- Sprecher bearbeiten

  void renameSpeaker(int i, String name) {
    if (i < 0 || i >= speakers.length || name.trim().isEmpty) return;
    speakers[i] = name.trim();
    notifyListeners();
  }

  /// Abschnitt einem anderen (oder neuen: -1) Sprecher zuordnen
  void reassign(TranscriptLine l, int speaker) {
    l.speaker = reassignIn(speakers, l, speaker);
    notifyListeners();
  }

  /// Für Live-Seite und Nachbearbeitung gemeinsam
  static int reassignIn(List<String> speakers, TranscriptLine l, int speaker) {
    if (speaker < 0) {
      speakers.add('Sprecher ${speakers.length + 1}');
      return speakers.length - 1;
    }
    return speaker;
  }

  void togglePause() {
    if (!active) return;
    paused = !paused;
    if (paused) {
      _pausedAt = DateTime.now();
      _vad.reset();
      _flushBackground();
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
    if (rest.isNotEmpty) _queue.add((_audioPos - Duration(milliseconds: rest.length * 1000 ~/ 16000), rest, false));
    _flushBackground();
    if (_queue.isNotEmpty) _worker ??= _work().whenComplete(() => _worker = null);
    await _worker;
    _wav?.close();
    _pausedAt ??= DateTime.now();
    notifyListeners();
  }

  void discard() {
    if (active) unawaited(stop());
    _wav?.close();
    _wav = null;
    try {
      _audioFile?.deleteSync();
    } catch (_) {}
    _audioFile = null;
    lines.clear();
    speakers.clear();
    _start = null;
    notifyListeners();
  }

  static String stamp(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  String get text => doc.interview();

  /// Mitschrift in einen neuen Chat: Mitschrift (zum Nachbearbeiten), Text, Aufnahme;
  /// danach fasst der Agent zusammen und stellt Rückfragen.
  Future<Conversation?> toChat({String title = ''}) async {
    if (lines.isEmpty) return null;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = title.trim().isNotEmpty ? title.trim() : 'Mitschrift ${now.day}.${now.month}. ${two(now.hour)}:${two(now.minute)}';
    final dir = app.outputsDir..createSync(recursive: true);
    final base = '${dir.path}/${name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')}';
    String? audio;
    final a = _audioFile;
    _wav = null;
    _audioFile = null;
    if (a != null && a.existsSync() && a.lengthSync() > 44) {
      audio = '$base.wav';
      try {
        await a.rename(audio);
      } catch (_) {
        await a.copy(audio);
        await a.delete();
      }
    }
    final t = MeetingTranscript(
      title: name,
      lines: List.of(lines),
      speakers: List.of(speakers),
      audio: audio,
      duration: elapsed,
      file: File('$base.mitschrift.json'),
    );
    await t.save();
    final who = t.usedSpeakers.length > 1 ? ' · ${t.usedSpeakers.length} Sprecher' : '';
    final c = Conversation(id: newId(), title: name, icon: 'post', color: 'blau');
    c.entries.add(ChatEntry(
      role: 'assistant',
      skill: 'Mitschrift',
      text: '📝 **$name** · ${stamp(t.duration)} · ${t.words} Wörter$who\n\n${t.interview(markdown: true)}',
      files: [t.file!.path, '$base.txt', if (audio != null) audio],
    ));
    app.conversations.insert(0, c);
    app.current = c;
    await app.storage.saveConversation(c);
    app.refreshUi();
    lines.clear();
    speakers.clear();
    _start = null;
    notifyListeners();
    // Gleich auswerten: Zusammenfassung + Rückfragen; Word auf Wunsch
    unawaited(app.send('Werte die Mitschrift oben aus: kurze Zusammenfassung (Thema, Teilnehmende, wichtigste Punkte, '
        'Entscheidungen, Aufgaben mit Zuständigen und Fristen). Die Sprecher sind automatisch erkannt'
        '${t.usedSpeakers.length > 1 ? ' (${t.usedSpeakers.map(t.speakerName).join(', ')})' : ''} – wenn aus dem Gespräch hervorgeht, '
        'wie jemand heißt, sag es mir. Stelle mir danach bis zu 3 Rückfragen zu Unklarem (z. B. wer etwas übernimmt, Namen, Termine). '
        'Biete am Ende an, alles als Word-Dokument abzulegen.'));
    return c;
  }
}
