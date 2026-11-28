// Mitschrift: Gespräch mitschreiben (auf dem Gerät), danach auswerten lassen.

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/meeting_audio.dart' show MeetingModels;
import '../state/transcriber.dart';
import 'theme.dart';
import 'transcript_view.dart';

Future<void> openTranscriber(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TranscribePage()));

class TranscribePage extends StatefulWidget {
  const TranscribePage({super.key});

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  final _title = TextEditingController();
  final _scroll = ScrollController();
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tr = AppScope.read(context).transcriber;
      if (!tr.active) tr.start();
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final app = AppScope.read(context);
    setState(() => _finishing = true);
    await app.transcriber.stop();
    final c = await app.transcriber.toChat(title: _title.text);
    if (!mounted) return;
    setState(() => _finishing = false);
    if (c == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nichts aufgenommen.')));
      return;
    }
    Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    final tr = AppScope.read(context).transcriber;
    if (tr.lines.isEmpty) {
      tr.discard();
      return true;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mitschrift verwerfen?'),
        content: const Text('Das bisher Mitgeschriebene geht verloren.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Weiter mitschreiben')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Verwerfen')),
        ],
      ),
    );
    if (ok == true) tr.discard();
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final tr = app.transcriber;
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: tr,
      builder: (context, _) {
        if (_scroll.hasClients) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
          });
        }
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            if (await _confirmDiscard() && context.mounted) Navigator.of(context).pop();
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Mitschrift'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Verwerfen',
                onPressed: () async {
                  if (await _confirmDiscard() && context.mounted) Navigator.of(context).pop();
                },
              ),
            ),
            body: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: 'Titel (optional)', hintText: 'z. B. Teammeeting Projekt X', isDense: true),
                ),
              ),
              // Status: Zeit, Pegel, Wörter
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Icon(Icons.fiber_manual_record, size: 14, color: tr.active && !tr.paused ? Colors.red.shade600 : c.faint),
                  const SizedBox(width: 8),
                  Text(MeetingTranscriber.stamp(tr.elapsed), style: t.titleLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ValueListenableBuilder<double>(
                      valueListenable: app.voice.mic.level,
                      builder: (context, lvl, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: tr.active && !tr.paused ? lvl.clamp(0, 1).toDouble() : 0,
                          minHeight: 6,
                          backgroundColor: c.raised,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('${tr.words} Wörter', style: t.bodySmall),
                ]),
              ),
              if (tr.error != null)
                Padding(padding: const EdgeInsets.all(16), child: Text(tr.error!, style: t.bodyMedium?.copyWith(color: scheme.error))),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(
                    tr.paused
                        ? 'Pausiert – es wird nichts aufgenommen.'
                        : tr.busy
                            ? 'Schreibt mit … (alles bleibt auf dem Gerät)'
                            : 'Hört zu – alles bleibt auf dem Gerät.',
                    style: t.bodySmall?.copyWith(color: c.muted)),
              ),
              if (!tr.models.installed) _ModelsCard(tr: tr),
              const SizedBox(height: 6),
              SpeakerBar(lines: tr.lines, speakers: tr.speakers, onRename: tr.renameSpeaker),
              const Divider(height: 16),
              Expanded(
                child: tr.lines.isEmpty
                    ? Center(child: Text('Sprich einfach – der Text erscheint hier.', style: t.bodyMedium?.copyWith(color: c.muted)))
                    : TranscriptLinesView(
                        controller: _scroll,
                        lines: tr.lines,
                        speakers: tr.speakers,
                        onChangeSpeaker: (block, s) {
                          if (block.isEmpty) {
                            tr.renameSpeaker(s, tr.speakers[s]);
                            return;
                          }
                          final to = MeetingTranscriber.reassignIn(tr.speakers, block.first, s);
                          for (final l in block) {
                            tr.reassign(l, to);
                          }
                        },
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: tr.active ? tr.togglePause : null,
                        icon: Icon(tr.paused ? Icons.play_arrow : Icons.pause),
                        label: Text(tr.paused ? 'Weiter' : 'Pause'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _finishing || (!tr.active && tr.lines.isEmpty) ? null : _finish,
                        icon: _finishing
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.check),
                        label: const Text('Fertig – auswerten'),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}


/// Hinweis: Sprecher, Musik und Geräusche erkennen – Zusatzmodelle einmal laden
class _ModelsCard extends StatelessWidget {
  const _ModelsCard({required this.tr});
  final MeetingTranscriber tr;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final p = tr.downloadProgress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: c.blueSoft, borderRadius: BorderRadius.circular(Ui.r)),
        child: Row(children: [
          Icon(Icons.record_voice_over_outlined, color: c.blue),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Sprecher, Musik & Geräusche erkennen', style: t.titleSmall),
              const SizedBox(height: 2),
              if (p == null)
                Text('Einmal ca. ${MeetingModels.sizeMb} MB laden – danach alles auf dem Gerät. Gilt ab jetzt auch für diese Aufnahme.',
                    style: t.bodySmall?.copyWith(color: c.muted))
              else ...[
                Text('${tr.downloadWhat} … ${(p * 100).round()} %', style: t.bodySmall?.copyWith(color: c.muted)),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: p, minHeight: 4),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          p == null
              ? FilledButton.tonal(onPressed: tr.downloadModels, child: const Text('Laden'))
              : TextButton(onPressed: tr.cancelDownload, child: const Text('Abbrechen')),
        ]),
      ),
    );
  }
}
