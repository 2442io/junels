// Mitschrift wie ein Interview-Transkript: Sprecher mit Namen und Farbe, Musik/Geräusche als Hinweise.
// Live (während der Aufnahme) und zum Nachbearbeiten (aus dem Chat: „Mitschrift öffnen“).

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_scope.dart';
import '../state/transcriber.dart';
import 'theme.dart';

Color speakerColor(BuildContext context, int i) {
  final c = AppColors.of(context);
  final all = [c.mint, c.blue, c.violet, c.amber, c.red, const Color(0xFF0EA5B7), const Color(0xFFDB2777), const Color(0xFF65A30D)];
  return i < 0 ? c.faint : all[i % all.length];
}

/// Sprecher umbenennen (Dialog)
Future<String?> askSpeakerName(BuildContext context, String current) async {
  final ctl = TextEditingController(text: current.startsWith('Sprecher ') ? '' : current);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Name für „$current“'),
      content: TextField(
        controller: ctl,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(hintText: 'z. B. Anna', labelText: 'Name'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Übernehmen')),
      ],
    ),
  );
  return r == null || r.trim().isEmpty ? null : r.trim();
}

/// Leiste mit den erkannten Sprechern – antippen zum Benennen
class SpeakerBar extends StatelessWidget {
  const SpeakerBar({super.key, required this.lines, required this.speakers, required this.onRename});
  final List<TranscriptLine> lines;
  final List<String> speakers;
  final void Function(int speaker, String name) onRename;

  @override
  Widget build(BuildContext context) {
    final counts = <int, int>{};
    for (final l in lines) {
      if (l.kind == 'speech' && l.speaker >= 0) counts[l.speaker] = (counts[l.speaker] ?? 0) + 1;
    }
    if (counts.isEmpty) return const SizedBox.shrink();
    final ids = counts.keys.toList()..sort();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final i in ids)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: CircleAvatar(backgroundColor: speakerColor(context, i), radius: 9),
                label: Text('${i < speakers.length ? speakers[i] : 'Sprecher ${i + 1}'} · ${counts[i]}'),
                tooltip: 'Namen geben',
                onPressed: () async {
                  final n = await askSpeakerName(context, i < speakers.length ? speakers[i] : 'Sprecher ${i + 1}');
                  if (n != null) onRename(i, n);
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Abschnitte als Interview: aufeinanderfolgende Abschnitte desselben Sprechers als ein Block.
class TranscriptLinesView extends StatelessWidget {
  const TranscriptLinesView({
    super.key,
    required this.lines,
    required this.speakers,
    required this.onChangeSpeaker,
    this.onPlay,
    this.playingAt,
    this.controller,
  });
  final List<TranscriptLine> lines;
  final List<String> speakers;

  /// Block (Abschnitte) einem Sprecher zuordnen; -1 = neuer Sprecher; null = nur umbenennen
  final void Function(List<TranscriptLine> block, int speaker) onChangeSpeaker;
  final void Function(TranscriptLine line)? onPlay;
  final Duration? playingAt;
  final ScrollController? controller;

  List<List<TranscriptLine>> get _blocks {
    final out = <List<TranscriptLine>>[];
    for (final l in lines) {
      final last = out.isEmpty ? null : out.last;
      if (last != null && l.kind == 'speech' && last.first.kind == 'speech' && last.first.speaker == l.speaker) {
        last.add(l);
      } else {
        out.add([l]);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final blocks = _blocks;
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: blocks.length,
      itemBuilder: (context, i) {
        final b = blocks[i];
        return b.first.kind == 'speech' ? _speech(context, b) : _event(context, b.first);
      },
    );
  }

  Widget _event(BuildContext context, TranscriptLine l) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final music = l.kind == 'music';
    final label = l.label.isNotEmpty ? l.label : (music ? 'Musik' : 'Geräusch');
    final span = l.end != null && l.end! - l.at >= const Duration(seconds: 2)
        ? '${MeetingTranscriber.stamp(l.at)}–${MeetingTranscriber.stamp(l.end!)}'
        : MeetingTranscriber.stamp(l.at);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: music ? c.violetSoft : c.raised,
            borderRadius: BorderRadius.circular(Ui.r),
          ),
          child: Column(children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(music ? Icons.music_note : Icons.graphic_eq, size: 16, color: music ? c.violet : c.muted),
              const SizedBox(width: 6),
              Text(label, style: t.labelLarge?.copyWith(color: music ? c.violet : c.muted)),
              const SizedBox(width: 8),
              MonoText(span, size: 11, color: c.faint),
              if (onPlay != null) ...[
                const SizedBox(width: 4),
                InkWell(onTap: () => onPlay!(l), child: Icon(Icons.play_circle_outline, size: 18, color: c.muted)),
              ],
            ]),
            if (l.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('„${l.text}“', textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic, color: c.muted)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _speech(BuildContext context, List<TranscriptLine> b) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final s = b.first.speaker;
    final name = s >= 0 && s < speakers.length ? speakers[s] : (s >= 0 ? 'Sprecher ${s + 1}' : '');
    final color = speakerColor(context, s);
    final playing = playingAt != null && b.any((l) => playingAt! >= l.at && playingAt! < (l.end ?? l.at + const Duration(seconds: 5)));
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (s >= 0)
          Padding(
            padding: const EdgeInsets.only(right: 10, top: 2),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _pickSpeaker(context, b),
              child: CircleAvatar(
                radius: 15,
                backgroundColor: color.withValues(alpha: 0.18),
                child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                    style: t.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        Expanded(
          child: Container(
            padding: playing ? const EdgeInsets.all(8) : EdgeInsets.zero,
            decoration: playing ? BoxDecoration(color: c.mintSoft, borderRadius: BorderRadius.circular(Ui.r)) : null,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (s >= 0)
                  InkWell(
                    onTap: () => _pickSpeaker(context, b),
                    child: Text(name, style: t.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w700)),
                  ),
                if (s >= 0) const SizedBox(width: 8),
                MonoText(MeetingTranscriber.stamp(b.first.at), size: 11, color: c.faint),
                if (onPlay != null) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () => onPlay!(b.first),
                    child: Padding(padding: const EdgeInsets.all(2), child: Icon(Icons.play_circle_outline, size: 18, color: c.muted)),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              SelectableText(b.map((l) => l.text).join(' '), style: t.bodyLarge),
            ]),
          ),
        ),
      ]),
    );
  }

  Future<void> _pickSpeaker(BuildContext context, List<TranscriptLine> b) async {
    final used = {for (final l in lines) if (l.kind == 'speech' && l.speaker >= 0) l.speaker}.toList()..sort();
    final r = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Wer spricht hier?')),
          for (final i in used)
            ListTile(
              leading: CircleAvatar(backgroundColor: speakerColor(ctx, i), radius: 8),
              title: Text(i < speakers.length ? speakers[i] : 'Sprecher ${i + 1}'),
              trailing: i == b.first.speaker ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, i),
            ),
          ListTile(leading: const Icon(Icons.person_add_alt), title: const Text('Neuer Sprecher'), onTap: () => Navigator.pop(ctx, -1)),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Diesen Sprecher umbenennen'), onTap: () => Navigator.pop(ctx, -2)),
        ]),
      ),
    );
    if (r == null || !context.mounted) return;
    if (r == -2) {
      final s = b.first.speaker;
      final n = await askSpeakerName(context, s >= 0 && s < speakers.length ? speakers[s] : 'Sprecher ${s + 1}');
      if (n != null && s >= 0) {
        while (speakers.length <= s) {
          speakers.add('Sprecher ${speakers.length + 1}');
        }
        speakers[s] = n;
        onChangeSpeaker(const [], s);
      }
      return;
    }
    onChangeSpeaker(b, r);
  }
}

/// Karte im Chat: „Mitschrift öffnen“
class TranscriptCard extends StatelessWidget {
  const TranscriptCard(this.path, {super.key});
  final String path;

  @override
  Widget build(BuildContext context) {
    final t = MeetingTranscript.load(path);
    final c = AppColors.of(context);
    if (t == null) return const SizedBox.shrink();
    final who = t.usedSpeakers.map(t.speakerName).join(', ');
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: CircleAvatar(backgroundColor: c.blueSoft, child: Icon(Icons.record_voice_over_outlined, color: c.blue)),
        title: Text('Mitschrift öffnen', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text([
          MeetingTranscriber.stamp(t.duration),
          '${t.words} Wörter',
          if (who.isNotEmpty) who,
          if (t.audio != null && File(t.audio!).existsSync()) 'mit Aufnahme',
        ].join(' · ')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TranscriptViewerPage(path: path))),
      ),
    );
  }
}

/// Mitschrift ansehen und nachbearbeiten: Sprecher benennen/zuordnen, Aufnahme anhören.
class TranscriptViewerPage extends StatefulWidget {
  const TranscriptViewerPage({super.key, required this.path});
  final String path;

  @override
  State<TranscriptViewerPage> createState() => _TranscriptViewerPageState();
}

class _TranscriptViewerPageState extends State<TranscriptViewerPage> {
  MeetingTranscript? _t;
  AudioPlayer? _player;
  Duration? _pos;
  bool _playing = false;
  bool _dirty = false;
  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    _t = MeetingTranscript.load(widget.path);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    if (_dirty) unawaited(_t?.save());
    super.dispose();
  }

  bool get _hasAudio => _t?.audio != null && File(_t!.audio!).existsSync();

  Future<void> _play(TranscriptLine l) async {
    if (!_hasAudio) return;
    var p = _player;
    if (p == null) {
      p = _player = AudioPlayer();
      _subs.add(p.onPositionChanged.listen((d) => setState(() => _pos = d)));
      _subs.add(p.onPlayerStateChanged.listen((s) => setState(() => _playing = s == PlayerState.playing)));
      await p.setSource(DeviceFileSource(_t!.audio!));
    }
    await p.seek(l.at);
    await p.resume();
  }

  void _changed() {
    _dirty = true;
    setState(() {});
    unawaited(_t?.save().then((_) => _dirty = false));
  }

  Future<void> _toChat() async {
    final t = _t;
    if (t == null) return;
    final app = AppScope.read(context);
    final conv = app.conversations.where((c) => c.entries.any((e) => e.files.contains(widget.path))).firstOrNull;
    if (conv == null) return;
    await t.save();
    app.current = conv;
    app.refreshUi();
    unawaited(app.send('Ich habe die Mitschrift korrigiert. Sprecher: ${t.usedSpeakers.map(t.speakerName).join(', ')}. '
        'Bitte nutze ab jetzt diese Fassung (Zusammenfassung und Aufgaben mit den richtigen Namen):\n\n${t.interview()}'));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    if (t == null) {
      return Scaffold(appBar: AppBar(title: const Text('Mitschrift')), body: const Center(child: Text('Mitschrift nicht gefunden.')));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Text kopieren',
            icon: const Icon(Icons.copy_outlined),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: t.interview()));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mitschrift kopiert')));
            },
          ),
          if (_playing)
            IconButton(tooltip: 'Anhalten', icon: const Icon(Icons.pause_circle_outline), onPressed: () => _player?.pause()),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
              [
                MeetingTranscriber.stamp(t.duration),
                '${t.words} Wörter',
                if (t.usedSpeakers.isNotEmpty) '${t.usedSpeakers.length} Sprecher – zum Benennen antippen',
                if (_hasAudio) 'mit Aufnahme (▶ zum Anhören)',
              ].join(' · '),
              style: tt.bodySmall?.copyWith(color: c.muted)),
        ),
        SpeakerBar(
          lines: t.lines,
          speakers: t.speakers,
          onRename: (i, n) {
            while (t.speakers.length <= i) {
              t.speakers.add('Sprecher ${t.speakers.length + 1}');
            }
            t.speakers[i] = n;
            _changed();
          },
        ),
        const Divider(height: 16),
        Expanded(
          child: TranscriptLinesView(
            lines: t.lines,
            speakers: t.speakers,
            playingAt: _playing ? _pos : null,
            onPlay: _hasAudio ? _play : null,
            onChangeSpeaker: (block, s) {
              if (block.isNotEmpty) {
                final to = MeetingTranscriber.reassignIn(t.speakers, block.first, s);
                for (final l in block) {
                  l.speaker = to;
                }
              }
              _changed();
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(children: [
              if (_hasAudio)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _playing ? _player?.pause() : _play(t.lines.first),
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    label: Text(_playing ? 'Pause' : 'Aufnahme anhören'),
                  ),
                ),
              if (_hasAudio) const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _toChat,
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Korrigiert an den Chat'),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
