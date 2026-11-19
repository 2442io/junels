// Mitte: Streaming-Chat mit aufklappbarem Thought Log und Eingabefeld.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart' show modelCatalog;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/voice_service.dart';
import 'conversation_page.dart';
import 'file_views.dart';
import 'markdown_lite.dart';
import 'prompt_editor.dart';
import 'system_check.dart';

class ChatView extends StatefulWidget {
  const ChatView({super.key});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scroll = ScrollController();
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      _stickToBottom = pos.pixels >= pos.maxScrollExtent - 80;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool force = false}) {
    if (!force && !_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final entries = app.current?.entries ?? const <ChatEntry>[];
    if (app.running) _scrollToBottom();

    return Column(
      children: [
        Expanded(
          child: entries.isEmpty
              ? _EmptyState(app: app)
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    itemCount: entries.length + 1,
                    itemBuilder: (context, i) {
                      if (i == entries.length) {
                        return Center(
                          child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 820), child: const _LiveStatus()),
                        );
                      }
                      final e = entries[i];
                      final live = app.running && i == entries.length - 1;
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 820),
                          child: e.role == 'user'
                              ? _UserBubble(entry: e, index: i)
                              : _AssistantMessage(entry: e, live: live, index: i),
                        ),
                      );
                    },
                  ),
                ),
        ),
        _InputBar(onSent: () => _scrollToBottom(force: true)),
      ],
    );
  }
}

// --------------------------------------------- Status unter der letzten Antwort

/// Zeigt unter der letzten Antwort, was gerade passiert und wie lange schon.
class _LiveStatus extends StatefulWidget {
  const _LiveStatus();

  @override
  State<_LiveStatus> createState() => _LiveStatusState();
}

class _LiveStatusState extends State<_LiveStatus> {
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final loading = app.status == EngineStatus.loading;
    final active = app.running || loading || app.warming;
    if (!active) {
      _tick?.cancel();
      _tick = null;
      return const SizedBox(height: 8);
    }
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    final since = app.running ? app.runStarted : (loading ? app.loadStarted : null);
    String label;
    if (loading) {
      label = 'Modell wird geladen';
    } else if (app.running) {
      final last = app.current?.entries.lastOrNull;
      final step = last?.steps.lastOrNull;
      if (last == null) {
        label = 'Agent arbeitet';
      } else if (last.text.isNotEmpty) {
        label = 'Schreibt die Antwort';
      } else if (step?.tool != null && step!.observation == null) {
        label = 'Nutzt ${step.tool}';
      } else if (last.steps.isNotEmpty) {
        label = 'Denkt nach (Schritt ${last.steps.length + 1})';
      } else {
        label = 'Liest die Anfrage';
      }
    } else {
      label = 'Modell wird vorbereitet';
    }
    final el = since == null ? '' : ' · ${formatDuration(DateTime.now().difference(since).inMilliseconds)}';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Row(children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary)),
        const SizedBox(width: 10),
        Flexible(
          child: Text('$label …$el',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- Leerzustand

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final noModel = app.models.isEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, size: 56, color: scheme.primary),
              const SizedBox(height: 12),
              Text('Offline Agent', style: t.headlineSmall),
              const SizedBox(height: 8),
              Text(
                noModel
                    ? 'Läuft vollständig auf diesem Gerät – ohne KI-API. '
                        'Der Systemcheck prüft dein Gerät und lädt das passende Modell.'
                    : app.status == EngineStatus.ready
                        ? 'Stell eine Frage oder hänge eine Datei an. Der Agent nutzt die aktiven lokalen Tools.'
                        : 'Wähle links ein Modell aus, um zu starten.',
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              if (noModel)
                FilledButton.icon(
                  onPressed: () => openSystemCheck(context),
                  icon: const Icon(Icons.speed_outlined),
                  label: const Text('Systemcheck & Modell laden'),
                )
              else if (app.status == EngineStatus.ready)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final s in const [
                      'Welcher Wochentag ist heute?',
                      'Was ist 15 % von 2.340 €?',
                      'Erkläre mir in 3 Sätzen, was ein Agent ist.',
                    ])
                      ActionChip(label: Text(s), onPressed: () => app.send(s)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Nachrichten

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.entry, required this.index});
  final ChatEntry entry;
  final int index;

  Future<void> _edit(BuildContext context) async {
    final app = AppScope.read(context);
    final ctrl = TextEditingController(text: entry.text);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nachricht bearbeiten'),
        content: SizedBox(
          width: 560,
          child: TextField(controller: ctrl, autofocus: true, minLines: 3, maxLines: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Senden')),
        ],
      ),
    );
    ctrl.dispose();
    if (text != null && text.trim().isNotEmpty) await app.resendFrom(index, newText: text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = AppScope.of(context);
    final actions = Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'Bearbeiten und neu senden',
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        icon: const Icon(Icons.edit_outlined),
        onPressed: app.running ? null : () => _edit(context),
      ),
      IconButton(
        tooltip: 'Wiederholen',
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        icon: const Icon(Icons.replay),
        onPressed: app.running ? null : () => app.resendFrom(index),
      ),
      IconButton(
        tooltip: 'Kopieren',
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        icon: const Icon(Icons.copy),
        onPressed: () => Clipboard.setData(ClipboardData(text: entry.text)),
      ),
    ]);
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4, left: 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (entry.files.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.end, children: [
                  for (final p in entry.files) ImagePreview(p, size: 120),
                ]),
              ),
            if (entry.attachments.any((a) => !isImageFile(a)))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final a in entry.attachments.where((a) => !isImageFile(a)))
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(Icons.attach_file, size: 16),
                        label: Text(a),
                      ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(16).copyWith(bottomRight: const Radius.circular(4)),
              ),
              child: Text.rich(TextSpan(children: [
                if (entry.viaVoice)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.mic, size: 14, color: scheme.onPrimaryContainer.withValues(alpha: 0.7)),
                    ),
                  ),
                TextSpan(text: entry.text),
              ]), style: TextStyle(color: scheme.onPrimaryContainer)),
            ),
            actions,
          ],
        ),
      ),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({required this.entry, required this.live, required this.index});
  final int index;
  final ChatEntry entry;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final waiting = live && entry.text.isEmpty && entry.steps.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8, right: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (entry.steps.isNotEmpty) _ThoughtLog(steps: entry.steps, live: live && entry.text.isEmpty),
          if (waiting)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Verarbeite Prompt …'),
              ]),
            ),
          if (entry.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: MarkdownLite(entry.text,
                  selectable: false, networkImages: AppScope.of(context).current?.internetAllowed ?? false),
            ),
          if (entry.error != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(entry.error!, style: TextStyle(color: scheme.onErrorContainer))),
              ]),
            ),
          if (entry.files.isNotEmpty) FileGallery(entry.files),
          if (!live && entry.sources.isNotEmpty) _Sources(entry.sources),
          if (!live && (entry.text.isNotEmpty || entry.tokensPerSecond != null || entry.error != null))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (entry.truncated)
                    Text('gekürzt · ', style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  if (entry.durationMs != null) ...[
                    Icon(Icons.timer_outlined, size: 13, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 3),
                    Text(formatDuration(entry.durationMs!), style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                    if (entry.tokensPerSecond != null)
                      Text(' · ', style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                  if (entry.tokensPerSecond != null)
                    Text('${entry.tokensPerSecond!.toStringAsFixed(1)} Tokens/s',
                        style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Neu generieren',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    icon: const Icon(Icons.refresh),
                    onPressed: AppScope.of(context).running ? null : () => AppScope.read(context).regenerate(index),
                  ),
                  if (entry.text.isNotEmpty) _SpeakButton(entry: entry),
                  if (entry.text.isNotEmpty)
                    IconButton(
                      tooltip: 'Antwort kopieren',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: entry.text));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Kopiert'), duration: Duration(seconds: 1)));
                      },
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Sources extends StatelessWidget {
  const _Sources(this.sources);
  final List<SourceRef> sources;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    IconData icon(String k) => switch (k) {
          'web' => Icons.public,
          'doc' => Icons.description_outlined,
          'tool' => Icons.calculate_outlined,
          _ => Icons.memory,
        };
    String label(SourceRef r) => switch (r.kind) {
          'model' => 'Modell: ${r.label}',
          'web' => r.label == r.url ? (Uri.tryParse(r.url!)?.host ?? r.label) : r.label,
          _ => r.label,
        };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Quellen:', style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          for (final r in sources)
            Tooltip(
              message: r.url ?? r.label,
              child: ActionChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                avatar: Icon(icon(r.kind), size: 14),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(label(r), overflow: TextOverflow.ellipsis, style: t.labelSmall),
                ),
                onPressed: r.url == null
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: r.url!));
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Adresse kopiert: ${r.url}'), duration: const Duration(seconds: 2)));
                      },
              ),
            ),
        ],
      ),
    );
  }
}

class _SpeakButton extends StatelessWidget {
  const _SpeakButton({required this.entry});
  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ValueListenableBuilder<Object?>(
      valueListenable: app.voice.speakingKey,
      builder: (context, key, _) {
        final speaking = identical(key, entry);
        return IconButton(
          tooltip: speaking ? 'Vorlesen stoppen' : 'Vorlesen',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: Icon(speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined),
          onPressed: () async {
            if (speaking) {
              await app.voice.stopSpeaking();
              return;
            }
            final messenger = ScaffoldMessenger.of(context);
            try {
              await app.speakText(entry.text, key: entry);
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('$e')));
            }
          },
        );
      },
    );
  }
}

/// Aufklappbares Protokoll der Denkschritte (Thought → Action → Observation).
class _ThoughtLog extends StatelessWidget {
  const _ThoughtLog({required this.steps, required this.live});
  final List<StepLog> steps;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final tools = steps.where((s) => s.tool != null).length;
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          // immer eingeklappt; bei Bedarf aufklappen
          initiallyExpanded: false,
          maintainState: true,
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: live
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(Icons.psychology_alt_outlined, color: scheme.primary),
          title: Text(
            live
                ? 'Denkt nach … Schritt ${steps.length}'
                : 'Denkschritte: ${steps.length} · $tools Tool-Aufruf${tools == 1 ? '' : 'e'}',
            style: t.bodyMedium,
          ),
          children: [
            for (final s in steps) _StepTile(step: s),
          ],
        ),
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step});
  final StepLog step;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Courier'],
      fontSize: 12,
      color: scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: scheme.secondaryContainer,
            child: Text('${step.step}', style: t.labelSmall),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (step.thought.isNotEmpty)
                  Text(step.thought, style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                if (step.tool != null) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    children: [
                      Chip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        avatar: const Icon(Icons.build_outlined, size: 14),
                        label: Text(step.tool!, style: t.labelSmall),
                      ),
                      if (step.args != null && step.args!.isNotEmpty)
                        Text(_shortArgs(step.args!), style: mono),
                    ],
                  ),
                ],
                if (step.observation != null)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(8),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: step.isError
                          ? scheme.errorContainer.withValues(alpha: 0.5)
                          : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      step.observation!.length > 600
                          ? '${step.observation!.substring(0, 600)} …'
                          : step.observation!,
                      style: mono,
                    ),
                  ),
                if (step.durationMs > 0)
                  Text('${step.durationMs} ms', style: t.labelSmall?.copyWith(color: scheme.outline)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _shortArgs(Map<String, dynamic> a) {
    final s = jsonEncode(a);
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }
}

// --------------------------------------------------------------------- Eingabe

class _MicButton extends StatelessWidget {
  const _MicButton({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<VoicePhase>(
      valueListenable: app.voice.phase,
      builder: (context, phase, _) {
        if (phase == VoicePhase.transcribing) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          );
        }
        if (phase == VoicePhase.recording) {
          return ValueListenableBuilder<double>(
            valueListenable: app.voice.level,
            builder: (context, level, _) => Stack(
              alignment: Alignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 30 + level * 18,
                  height: 30 + level * 18,
                  decoration: BoxDecoration(color: scheme.error.withValues(alpha: 0.18), shape: BoxShape.circle),
                ),
                IconButton(
                  tooltip: 'Aufnahme beenden',
                  icon: Icon(Icons.stop_circle, color: scheme.error),
                  onPressed: onTap,
                ),
                Positioned(
                  bottom: 0,
                  child: ValueListenableBuilder<int>(
                    valueListenable: app.voice.recordSeconds,
                    builder: (context, s, _) =>
                        Text('0:${s.toString().padLeft(2, '0')}', style: Theme.of(context).textTheme.labelSmall),
                  ),
                ),
              ],
            ),
          );
        }
        return IconButton(
          tooltip: 'Spracheingabe (Whisper)',
          icon: const Icon(Icons.mic_none),
          onPressed: onTap,
        );
      },
    );
  }
}

class _InputBar extends StatefulWidget {
  const _InputBar({required this.onSent});
  final VoidCallback onSent;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  final _ctrl = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // Enter sendet, Shift+Enter = neue Zeile (Hardware-Tastatur auf Mac/iPad).
  // Android ausgenommen: manche Bildschirmtastaturen senden Enter als Tastenereignis.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if ((Platform.isMacOS || Platform.isIOS) &&
        e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _send() {
    final app = AppScope.read(context);
    if (app.running || app.status != EngineStatus.ready) return;
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    app.send(text);
    widget.onSent();
  }

  Future<void> _toggleVoice() async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final v = app.voice;
    if (v.phase.value == VoicePhase.recording) {
      try {
        final text = await app.finishVoiceInput();
        if (text.trim().isEmpty) {
          messenger.showSnackBar(const SnackBar(content: Text('Nichts verstanden – bitte nochmal.')));
          return;
        }
        final existing = _ctrl.text.trim();
        _ctrl.text = existing.isEmpty ? text.trim() : '$existing ${text.trim()}';
        _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
        if (app.settings.sendAfterVoice) _send();
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (v.phase.value != VoicePhase.idle) return;
    if (app.sttModelPath == null) {
      messenger.showSnackBar(SnackBar(
        content: const Text('Für Spracheingabe zuerst ein Whisper-Modell laden.'),
        action: SnackBarAction(label: 'Systemcheck', onPressed: () => openSystemCheck(context)),
      ));
      return;
    }
    try {
      await v.startRecording();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _attach() async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final res = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.any);
    if (res == null) return;
    var image = false;
    for (final f in res.files) {
      if (f.path == null) continue;
      final err = await app.addAttachment(f.path!, f.name);
      if (err != null) messenger.showSnackBar(SnackBar(content: Text(err), duration: const Duration(seconds: 6)));
      if (err == null && isImageFile(f.name)) image = true;
    }
    if (image && !app.canSeeImages) {
      messenger.showSnackBar(SnackBar(
        content: Text(app.visionHint),
        duration: const Duration(seconds: 8),
        action: app.engine != null && app.modelSupportsVision
            ? SnackBarAction(label: 'Laden', onPressed: () {
                final c = modelCatalog.where((e) => e.id == app.loadedModel?.catalogId).firstOrNull;
                if (c != null) app.downloadVision(c);
              })
            : null,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final ready = app.status == EngineStatus.ready;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (app.imageProgress != null)
                    Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                        child: Row(children: [
                          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 10),
                          Expanded(child: Text(app.imageProgress!)),
                          TextButton(onPressed: app.cancelImage, child: const Text('Abbrechen')),
                        ]),
                      ),
                    ),
                  if (app.attachments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final a in app.attachments)
                            InputChip(
                              avatar: a.path != null && isImageFile(a.name)
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: Image.file(File(a.path!), width: 24, height: 24, fit: BoxFit.cover, cacheWidth: 64),
                                    )
                                  : Icon(a.name.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf_outlined : Icons.description_outlined, size: 16),
                              label: Text(isImageFile(a.name) ? a.name : '${a.name} (${(a.content.length / 1000).toStringAsFixed(1)}k)'),
                              onDeleted: app.running ? null : () => app.removeAttachment(a),
                            ),
                        ],
                      ),
                    ),
                  LayoutBuilder(builder: (context, box) {
                    final tools = <Widget>[
                      IconButton(
                        tooltip: 'Datei anhängen (PDF, Bilder, TXT, MD, CSV, JSON)',
                        icon: const Icon(Icons.attach_file),
                        onPressed: app.running ? null : _attach,
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Prompts & Vorlagen',
                        icon: const Icon(Icons.bolt_outlined),
                        enabled: !app.running,
                        onSelected: (v) {
                          if (v == '__save__') {
                            editPrompt(context, initialText: _ctrl.text);
                            return;
                          }
                          if (v.startsWith('__run__')) {
                            final p = app.prompts.where((x) => x.id == v.substring(7)).firstOrNull;
                            if (p != null) runSavedPrompt(context, app, p);
                            return;
                          }
                          _ctrl.text = v;
                          _ctrl.selection = TextSelection.collapsed(offset: v.length);
                          _focus.requestFocus();
                        },
                        itemBuilder: (_) => [
                          for (final p in app.prompts)
                            PopupMenuItem(
                              value: '__run__${p.id}',
                              child: ListTile(
                                dense: true,
                                leading: const Icon(Icons.play_arrow, size: 20),
                                title: Text(p.title),
                                subtitle: p.schedule == ScheduleKind.off ? null : Text(p.scheduleLabel),
                              ),
                            ),
                          if (app.prompts.isNotEmpty) const PopupMenuDivider(),
                          for (final (label, text) in promptPresets)
                            PopupMenuItem(value: text, child: Text(label)),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: '__save__',
                            child: ListTile(dense: true, leading: Icon(Icons.bookmark_add_outlined, size: 20), title: Text('Eingabe als Prompt speichern …')),
                          ),
                        ],
                      ),
                      _MicButton(onTap: app.running ? null : _toggleVoice),
                      IconButton(
                        tooltip: 'Gesprächsmodus – freihändig sprechen',
                        icon: const Icon(Icons.record_voice_over_outlined),
                        onPressed: ready && !app.running ? () => openConversation(context) : null,
                      ),
                    ];
                    final field = TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 6,
                      enabled: ready,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: !ready
                            ? 'Zuerst ein Modell laden'
                            : (app.warming ? 'Modell wird vorbereitet … (du kannst schon schreiben)' : 'Nachricht an den Agenten …'),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    );
                    final sendButton = SizedBox(
                      width: 48,
                      height: 48,
                      child: app.running
                          ? IconButton.filledTonal(
                              tooltip: 'Stopp',
                              icon: const Icon(Icons.stop_rounded),
                              onPressed: app.stop,
                            )
                          : IconButton.filled(
                              tooltip: 'Senden',
                              icon: const Icon(Icons.arrow_upward_rounded),
                              onPressed: ready ? _send : null,
                            ),
                    );
                    final inputRow = Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [Expanded(child: field), const SizedBox(width: 8), sendButton],
                    );
                    // Schmale Bildschirme (Handy): Icons in eigener Zeile über einer durchgehenden Eingabe
                    if (box.maxWidth < 640) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(children: [
                            for (final w in tools)
                              IconTheme.merge(data: const IconThemeData(size: 22), child: w),
                          ]),
                          const SizedBox(height: 2),
                          inputRow,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [...tools, const SizedBox(width: 4), Expanded(child: inputRow)],
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
