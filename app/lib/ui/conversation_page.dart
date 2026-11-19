// Vollbild-Gesprächsmodus: sprechen wie mit einem Menschen.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/conversation_mode.dart';
import 'system_check.dart';

Future<void> openConversation(BuildContext context) async {
  final app = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  if (app.sttModelPath == null) {
    messenger.showSnackBar(SnackBar(
      content: const Text('Für den Gesprächsmodus zuerst ein Whisper-Modell laden.'),
      action: SnackBarAction(label: 'Systemcheck', onPressed: () => openSystemCheck(context)),
    ));
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => const ConversationPage(),
  ));
}

class ConversationPage extends StatefulWidget {
  const ConversationPage({super.key});

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  late final ConversationMode conv = AppScope.read(context).conversation;
  String? _startError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await conv.start();
      } catch (e) {
        if (mounted) setState(() => _startError = e.toString());
      }
    });
  }

  @override
  void dispose() {
    conv.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Gespräch'),
        actions: [
          IconButton(
            tooltip: 'Einstellungen',
            icon: const Icon(Icons.tune),
            onPressed: () => _showVoiceSettings(context),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                app.ttsVoicePath != null ? 'Stimme: Piper' : 'Stimme: System',
                style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _startError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_startError!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                ),
              )
            : ValueListenableBuilder<ConvState>(
                valueListenable: conv.state,
                builder: (context, st, _) => Column(
                  children: [
                    const SizedBox(height: 12),
                    // was der Nutzer zuletzt gesagt hat
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ValueListenableBuilder<String>(
                        valueListenable: conv.userText,
                        builder: (context, u, _) => Text(
                          u.isEmpty ? 'Sag einfach etwas …' : '„$u“',
                          textAlign: TextAlign.center,
                          style: t.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: GestureDetector(
                          onTap: () => st == ConvState.hearing && conv.manualEnd.value ? conv.finishSpeaking() : conv.interrupt(),
                          child: ValueListenableBuilder<double>(
                            valueListenable: conv.level,
                            builder: (context, lvl, _) => _Orb(state: st, level: lvl),
                          ),
                        ),
                      ),
                    ),
                    Text(st.label, style: t.titleMedium),
                    ValueListenableBuilder<bool>(
                      valueListenable: conv.manualEnd,
                      builder: (context, manual, _) {
                        if (!manual) return const SizedBox(height: 8);
                        if (st == ConvState.hearing) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                TextButton.icon(
                                  onPressed: conv.discardSpeaking,
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('Verwerfen'),
                                ),
                                const SizedBox(width: 12),
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18)),
                                  onPressed: conv.finishSpeaking,
                                  icon: const Icon(Icons.send),
                                  label: const Text('Fertig – antworten'),
                                ),
                              ],
                            ),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 8),
                          child: Text(
                            st == ConvState.listening ? 'Absender-Modus: sprich, dann auf „Fertig“ tippen' : '',
                            style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        );
                      },
                    ),
                    // Antwort des Agenten (live)
                    SizedBox(
                      height: 140,
                      child: SingleChildScrollView(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: ValueListenableBuilder<String>(
                          valueListenable: conv.agentText,
                          builder: (context, a, _) => Text(
                            a,
                            textAlign: TextAlign.center,
                            style: t.bodyLarge,
                          ),
                        ),
                      ),
                    ),
                    ValueListenableBuilder<String?>(
                      valueListenable: conv.error,
                      builder: (context, e, _) => e == null
                          ? const SizedBox(height: 8)
                          : Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(e, style: t.bodySmall?.copyWith(color: scheme.error), textAlign: TextAlign.center),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ValueListenableBuilder<bool>(
                            valueListenable: conv.muted,
                            builder: (context, m, _) => _RoundButton(
                              icon: m ? Icons.mic_off : Icons.mic,
                              label: m ? 'Stumm' : 'Mikrofon',
                              onTap: conv.toggleMute,
                              active: !m,
                            ),
                          ),
                          _RoundButton(
                            icon: Icons.pan_tool_outlined,
                            label: 'Unterbrechen',
                            onTap: st == ConvState.speaking || st == ConvState.thinking ? conv.interrupt : null,
                          ),
                          _RoundButton(
                            icon: Icons.call_end,
                            label: 'Beenden',
                            color: scheme.error,
                            onTap: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

void _showVoiceSettings(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      final app = AppScope.of(ctx);
      final st = app.settings;
      final t = Theme.of(ctx).textTheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Wann bin ich fertig?', style: t.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.hourglass_bottom), label: Text('Sprechpause')),
                  ButtonSegment(value: true, icon: Icon(Icons.send), label: Text('Fertig-Taste')),
                ],
                selected: {st.voiceManualEnd},
                onSelectionChanged: (v) => app.setVoiceOptions(manualEnd: v.first),
              ),
              const SizedBox(height: 6),
              Text(
                st.voiceManualEnd
                    ? 'Absender-Modus: Pausen beenden nichts. Du tippst auf „Fertig – antworten“ (oder den Kreis).'
                    : 'Die Antwort startet nach einer Sprechpause.',
                style: t.bodySmall,
              ),
              if (!st.voiceManualEnd) ...[
                const SizedBox(height: 16),
                Text('Sprechpause: ${(st.voicePauseMs / 1000).toStringAsFixed(1)} s', style: t.titleSmall),
                Slider(
                  value: st.voicePauseMs.toDouble().clamp(600, 3000),
                  min: 600,
                  max: 3000,
                  divisions: 12,
                  label: '${(st.voicePauseMs / 1000).toStringAsFixed(1)} s',
                  onChanged: (v) => app.setVoiceOptions(pauseMs: v.round()),
                ),
                Text('Länger = mehr Zeit zum Überlegen, ohne dass der Agent dazwischenredet.', style: t.bodySmall),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Nur meine Stimme'),
                subtitle: const Text('Leisere Stimmen im Hintergrund (andere Personen, Durchsagen) ignorieren'),
                value: st.voiceNearField,
                onChanged: (v) => app.setVoiceOptions(nearField: v),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: app.conversation.smartVad,
                builder: (context, smart, _) => Row(
                  children: [
                    Icon(smart ? Icons.check_circle : Icons.info_outline, size: 16,
                        color: smart ? Colors.green : Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        smart
                            ? 'Spracherkennung per KI (Silero) aktiv – Lärm wie in der U-Bahn wird ignoriert.'
                            : 'Einfache Lautstärke-Erkennung aktiv (Silero nicht verfügbar).',
                        style: t.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Orb extends StatelessWidget {
  const _Orb({required this.state, required this.level});
  final ConvState state;
  final double level;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (state) {
      ConvState.listening => scheme.primary,
      ConvState.hearing => Colors.green,
      ConvState.transcribing || ConvState.thinking => Colors.amber,
      ConvState.speaking => scheme.tertiary,
      ConvState.off => scheme.outline,
    };
    final active = state == ConvState.hearing || state == ConvState.listening;
    final size = 150.0 + (active ? level * 70 : 0) + (state == ConvState.speaking ? 20 : 0);
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: size + 60,
          height: size + 60,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.10)),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [color.withValues(alpha: 0.95), color.withValues(alpha: 0.55)]),
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 40, spreadRadius: 4)],
          ),
          child: Center(
            child: state == ConvState.thinking || state == ConvState.transcribing
                ? const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                : Icon(
                    state == ConvState.speaking ? Icons.graphic_eq : Icons.mic,
                    size: 48 + math.min(level * 20, 20),
                    color: Colors.white,
                  ),
          ),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, this.onTap, this.color, this.active = true});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = color ?? (active ? scheme.secondaryContainer : scheme.surfaceContainerHighest);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: onTap == null ? bg.withValues(alpha: 0.4) : bg,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon, color: color != null ? Colors.white : scheme.onSecondaryContainer),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
