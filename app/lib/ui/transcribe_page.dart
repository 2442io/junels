import 'dart:math' as math;

// Mitschrift: Gespräch mitschreiben (auf dem Gerät), danach auswerten lassen.

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/meeting_audio.dart' show MeetingModels;
import '../state/transcriber.dart';
import 'theme.dart';
import 'transcript_view.dart';
import '../l10n.dart';

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
      final trn = AppScope.read(context).transcriber;
      if (!trn.active) trn.start();
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Nichts aufgenommen.'))));
      return;
    }
    Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    final trn = AppScope.read(context).transcriber;
    if (trn.lines.isEmpty) {
      trn.discard();
      return true;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Mitschrift verwerfen?')),
        content: Text(tr('Das bisher Mitgeschriebene geht verloren.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Weiter mitschreiben'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Verwerfen'))),
        ],
      ),
    );
    if (ok == true) trn.discard();
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final trn = app.transcriber;
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: trn,
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
              title: Text(tr('Mitschrift')),
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: tr('Verwerfen'),
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
                  decoration: InputDecoration(labelText: tr('Titel (optional)'), hintText: tr('z. B. Teammeeting Projekt X'), isDense: true),
                ),
              ),
              // Status: Zeit, Pegel, Wörter
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Icon(Icons.fiber_manual_record, size: 14, color: trn.active && !trn.paused ? Colors.red.shade600 : c.faint),
                  const SizedBox(width: 8),
                  Text(MeetingTranscriber.stamp(trn.elapsed), style: t.titleLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  const SizedBox(width: 12),
                  const Spacer(),
                  const SizedBox(width: 12),
                  Text('${trn.words} Wörter', style: t.bodySmall),
                ]),
              ),
              // Tonwelle: bewegt sich mit der Lautstärke, ruhig in der Pause
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: ValueListenableBuilder<double>(
                  valueListenable: app.voice.mic.level,
                  builder: (context, lvl, _) => LevelWave(level: trn.active && !trn.paused ? lvl.clamp(0, 1).toDouble() : 0, live: trn.active && !trn.paused),
                ),
              ),
              if (trn.error != null)
                Padding(padding: const EdgeInsets.all(16), child: Text(trn.error!, style: t.bodyMedium?.copyWith(color: scheme.error))),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(
                    trn.paused
                        ? tr('Pausiert – es wird nichts aufgenommen.')
                        : trn.busy
                            ? tr('Schreibt mit … (alles bleibt auf dem Gerät)')
                            : tr('Hört zu – alles bleibt auf dem Gerät.'),
                    style: t.bodySmall?.copyWith(color: c.muted)),
              ),
              if (!trn.models.installed) _ModelsCard(trn: trn),
              const SizedBox(height: 6),
              SpeakerBar(lines: trn.lines, speakers: trn.speakers, onRename: trn.renameSpeaker),
              const Divider(height: 16),
              Expanded(
                child: trn.lines.isEmpty
                    ? Center(child: Text(tr('Sprich einfach – der Text erscheint hier.'), style: t.bodyMedium?.copyWith(color: c.muted)))
                    : TranscriptLinesView(
                        controller: _scroll,
                        lines: trn.lines,
                        speakers: trn.speakers,
                        onChangeSpeaker: (block, s) {
                          if (block.isEmpty) {
                            trn.renameSpeaker(s, trn.speakers[s]);
                            return;
                          }
                          final to = MeetingTranscriber.reassignIn(trn.speakers, block.first, s);
                          for (final l in block) {
                            trn.reassign(l, to);
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
                        onPressed: trn.active ? trn.togglePause : null,
                        icon: Icon(trn.paused ? Icons.play_arrow : Icons.pause),
                        label: Text(trn.paused ? tr('Weiter') : 'Pause'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _finishing || (!trn.active && trn.lines.isEmpty) ? null : _finish,
                        icon: _finishing
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.check),
                        label: Text(tr('Fertig – auswerten')),
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
  const _ModelsCard({required this.trn});
  final MeetingTranscriber trn;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final p = trn.downloadProgress;
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
              Text(tr('Sprecher, Musik & Geräusche erkennen'), style: t.titleSmall),
              const SizedBox(height: 2),
              if (p == null)
                Text('Einmal ca. ${MeetingModels.sizeMb} MB laden – danach alles auf dem Gerät. Gilt ab jetzt auch für diese Aufnahme.',
                    style: t.bodySmall?.copyWith(color: c.muted))
              else ...[
                Text('${trn.downloadWhat} … ${(p * 100).round()} %', style: t.bodySmall?.copyWith(color: c.muted)),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: p, minHeight: 4),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          p == null
              ? FilledButton.tonal(onPressed: trn.downloadModels, child: Text(tr('Laden')))
              : TextButton(onPressed: trn.cancelDownload, child: Text(tr('Abbrechen'))),
        ]),
      ),
    );
  }
}


/// Tonwelle wie ein Sprachmemo: runde Balken, in der Mitte höher – freundlich in den Junels-Farben
/// (Mint → Blau → Violett). Bewegen sich weich mit der Stimme; in der Pause atmen sie ruhig.
class LevelWave extends StatefulWidget {
  const LevelWave({super.key, required this.level, this.live = true, this.height = 104});
  final double level;
  final bool live;
  final double height;

  @override
  State<LevelWave> createState() => _LevelWaveState();
}

class _LevelWaveState extends State<LevelWave> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  double _smooth = 0;
  static const _bars = 15;
  // Grundform: in der Mitte am höchsten, leicht unregelmäßig wie echte Sprache
  static const _shape = [0.26, 0.34, 0.46, 0.62, 0.55, 0.78, 0.9, 1.0, 0.86, 0.72, 0.8, 0.6, 0.48, 0.36, 0.26];
  final _bar = List<double>.filled(_bars, 0.12);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = [c.mint, c.blue, c.violet];
    Color at(double u) => u < 0.5 ? Color.lerp(colors[0], colors[1], u * 2)! : Color.lerp(colors[1], colors[2], (u - 0.5) * 2)!;
    return Container(
      height: widget.height + 20,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Ui.rLg),
        gradient: LinearGradient(
          colors: dark
              ? [c.mint.withValues(alpha: 0.08), c.blue.withValues(alpha: 0.08), c.violet.withValues(alpha: 0.10)]
              : [c.mintSoft, c.blueSoft, c.violetSoft],
        ),
      ),
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (context, _) {
          final target = widget.live ? (0.16 + widget.level * 2.0).clamp(0.0, 1.0) : 0.0;
          _smooth += (target - _smooth) * 0.18;
          final t = _ctl.value * 2 * math.pi;
          return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < _bars; i++)
              Builder(builder: (context) {
                // jeder Balken schwingt etwas anders; ohne Stimme sanftes Atmen
                final wobble = 0.72 + 0.28 * math.sin(t * (1.0 + (i % 4) * 0.23) + i * 0.8);
                final idle = 0.10 + 0.05 * (0.5 + 0.5 * math.sin(t + i * 0.45));
                final goal = widget.live ? math.max(idle, _smooth * wobble) : idle;
                _bar[i] += (goal - _bar[i]) * 0.3;
                final h = 10 + (widget.height - 10) * _shape[i] * _bar[i];
                final col = at(i / (_bars - 1));
                return Container(
                  width: 10,
                  height: h,
                  margin: const EdgeInsets.symmetric(horizontal: 3.5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [col.withValues(alpha: 0.65), col, col.withValues(alpha: 0.65)],
                    ),
                    boxShadow: [if (widget.live) BoxShadow(color: col.withValues(alpha: 0.25), blurRadius: 8, offset: const Offset(0, 2))],
                  ),
                );
              }),
          ]);
        },
      ),
    );
  }
}
