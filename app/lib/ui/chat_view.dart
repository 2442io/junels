// Mitte: Streaming-Chat mit aufklappbarem Thought Log und Eingabefeld.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart' show modelCatalog, cleanModelText;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/smtp.dart';
import '../state/vault.dart';
import '../state/voice_service.dart';
import 'conversation_page.dart';
import 'file_views.dart';
import 'markdown_lite.dart';
import 'theme.dart';
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
    if (app.runningHere) _scrollToBottom();

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
                      final live = app.runningHere && i == entries.length - 1;
                      return Center(
                        key: ObjectKey(e),
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

// ------------------------------------------------------ Ergebnis-Karussell

/// Web-Inhalte (Produkte, Meldungen, Treffer) als horizontal wischbare Karten:
/// Bild, Titel, Text, Preis, externer Link – mit „Weitere laden“.
class ResultCarousel extends StatefulWidget {
  const ResultCarousel({super.key, required this.cards, this.loadImages = true, this.onMore});
  final List<Map<String, String>> cards;
  final bool loadImages;
  final VoidCallback? onMore;

  @override
  State<ResultCarousel> createState() => _ResultCarouselState();
}

class _ResultCarouselState extends State<ResultCarousel> {
  static const _page = 10;
  int _shown = _page;
  String? _tag; // gewählte Kategorie (null = alle)

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    // Kategorien (Thema der Nachrichten, Suchbegriff …) in der Reihenfolge des Auftretens
    final tags = <String, int>{};
    for (final c in widget.cards) {
      final g = (c['tag'] ?? '').trim();
      if (g.isNotEmpty) tags[g] = (tags[g] ?? 0) + 1;
    }
    final cards = _tag == null ? widget.cards : widget.cards.where((c) => c['tag'] == _tag).toList();
    final visible = cards.take(_shown).toList();
    final rest = cards.length - visible.length;
    final extra = rest > 0 || widget.onMore != null ? 1 : 0;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (tags.length >= 2)
          SizedBox(
            height: 40,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text('Alle (${widget.cards.length})'),
                  selected: _tag == null,
                  onSelected: (_) => setState(() {
                    _tag = null;
                    _shown = _page;
                  }),
                ),
              ),
              for (final e in tags.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text('${e.key} (${e.value})'),
                    selected: _tag == e.key,
                    onSelected: (_) => setState(() {
                      _tag = e.key;
                      _shown = _page;
                    }),
                  ),
                ),
            ]),
          ),
        if (tags.length >= 2) const SizedBox(height: 8),
        SizedBox(
        height: 300,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: visible.length + extra,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (context, i) {
            if (i == visible.length) {
              // Ende: weitere Karten zeigen bzw. neu suchen lassen
              return SizedBox(
                width: 140,
                child: Card(
                  margin: EdgeInsets.zero,
                  child: InkWell(
                    onTap: rest > 0 ? () => setState(() => _shown += _page) : widget.onMore,
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(rest > 0 ? Icons.arrow_forward : Icons.search, color: scheme.primary, size: 32),
                      const SizedBox(height: 8),
                      Text(rest > 0 ? 'Weitere laden\n($rest)' : 'Mehr suchen', textAlign: TextAlign.center,
                          style: t.labelLarge?.copyWith(color: scheme.primary)),
                    ]),
                  ),
                ),
              );
            }
            final c = visible[i];
            final link = c['link'] ?? '';
            final img = c['image'] ?? '';
            final host = Uri.tryParse(link)?.host.replaceFirst('www.', '') ?? '';
            final note = c['note'] ?? '';
            Widget placeholder() => host.isEmpty || !widget.loadImages
                ? Icon(Icons.public, size: 40, color: scheme.outline)
                : Image.network('https://$host/favicon.ico',
                    width: 40,
                    height: 40,
                    errorBuilder: (_, __, ___) => Icon(Icons.public, size: 40, color: scheme.outline));
            return SizedBox(
              width: 190,
              child: Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: link.isEmpty ? null : () => openExternalLink(context, link),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      height: 112,
                      color: img.isEmpty ? scheme.surfaceContainerHighest : Colors.white,
                      alignment: Alignment.center,
                      child: img.isEmpty || !widget.loadImages
                          ? placeholder()
                          : Image.network(
                              img,
                              fit: BoxFit.cover,
                              height: 112,
                              width: 190,
                              cacheWidth: 420,
                              errorBuilder: (_, __, ___) => placeholder(),
                              loadingBuilder: (_, child, p) => p == null
                                  ? child
                                  : const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                            ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          if ((c['tag'] ?? '').isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Text(c['tag']!.toUpperCase(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: t.labelSmall?.copyWith(color: scheme.primary, letterSpacing: 0.8, fontWeight: FontWeight.w700)),
                            ),
                          Text(c['title'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                          if (note.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Expanded(
                              child: Text(note, maxLines: 4, overflow: TextOverflow.ellipsis,
                                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            ),
                          ] else
                            const Spacer(),
                          if ((c['price'] ?? '').isNotEmpty)
                            Text(c['price']!, style: t.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 6, 6),
                      child: Row(children: [
                        Expanded(
                          child: Text(host, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ),
                        if (link.isNotEmpty) Icon(Icons.open_in_new, size: 16, color: scheme.primary),
                      ]),
                    ),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
      ]),
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
    final active = app.runningHere || loading || app.warming;
    if (!active) {
      _tick?.cancel();
      _tick = null;
      return const SizedBox(height: 8);
    }
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    final since = app.runningHere ? app.runStarted : (loading ? app.loadStarted : null);
    String label;
    if (loading) {
      label = 'Modell wird geladen';
    } else if (app.runningHere) {
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

  static const _ideas = <(IconData, String, String)>[
    (Icons.wb_sunny_outlined, 'Wetter', 'Wie wird das Wetter morgen in Wien?'),
    (Icons.newspaper, 'Nachrichten', 'Was sind die wichtigsten Tech-News heute?'),
    (Icons.slideshow_outlined, 'Präsentation', 'Erstelle eine Präsentation mit 5 Folien über die Vorteile lokaler KI.'),
    (Icons.travel_explore, 'Im Web suchen', 'Such auf geizhals.at nach einem leisen Staubsauger-Roboter.'),
    (Icons.calculate_outlined, 'Rechnen', 'Was sind 15 % von 2.340 €?'),
    (Icons.schedule, 'Automatisieren', 'Schick mir jeden Montag um 8 Uhr eine Wochenvorschau meiner Termine.'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final noModel = app.models.isEmpty && !app.canChat;
    final hour = DateTime.now().hour;
    final greet = hour < 11 ? 'Guten Morgen' : (hour < 18 ? 'Hallo' : 'Guten Abend');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandMark(size: 52),
              const SizedBox(height: 18),
              Text(noModel ? 'Willkommen bei Junels' : '$greet! Woran arbeiten wir?',
                  style: t.headlineSmall?.copyWith(fontSize: 26), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                noModel
                    ? 'Dein KI-Agent läuft auf diesem Gerät. Der Systemcheck prüft dein Gerät und lädt das passende Modell – '
                        'oder du bindest einen eigenen Server bzw. Cloud-Anbieter an.'
                    : app.canChat
                        ? 'Frag etwas, häng eine Datei an oder gib einen Auftrag. ${app.routingLabel == null ? 'Alles läuft lokal.' : app.routingLabel!}'
                        : 'Wähle ein Modell, um zu starten.',
                textAlign: TextAlign.center,
                style: t.bodyLarge?.copyWith(color: c.muted),
              ),
              const SizedBox(height: 26),
              if (noModel || !app.canChat)
                Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
                  FilledButton.icon(
                    onPressed: () => openSystemCheck(context),
                    icon: const Icon(Icons.speed_outlined, size: 18),
                    label: const Text('Systemcheck & Modell laden'),
                  ),
                ])
              else
                LayoutBuilder(builder: (context, box) {
                  final cols = box.maxWidth >= 560 ? 3 : 2;
                  final w = (box.maxWidth - (cols - 1) * 10) / cols;
                  return Wrap(spacing: 10, runSpacing: 10, children: [
                    for (final (icon, title, text) in _ideas)
                      SizedBox(
                        width: w,
                        child: Panel(
                          padding: const EdgeInsets.all(14),
                          onTap: () => app.send(text),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Icon(icon, size: 20, color: c.mint),
                            const SizedBox(height: 10),
                            Text(title, style: t.titleSmall),
                            const SizedBox(height: 4),
                            Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodySmall),
                          ]),
                        ),
                      ),
                  ]);
                }),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.of(context).raised,
                border: Border.all(color: AppColors.of(context).border),
                borderRadius: BorderRadius.circular(18).copyWith(bottomRight: const Radius.circular(6)),
              ),
              child: Text.rich(TextSpan(children: [
                if (entry.viaVoice)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.mic, size: 14, color: scheme.onSurfaceVariant),
                    ),
                  ),
                TextSpan(text: entry.text),
                if (app.isQueued(entry))
                  TextSpan(
                    text: '\n⏳ wartet auf die laufende Antwort',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
              ]), style: Theme.of(context).textTheme.bodyLarge),
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
              child: MarkdownLite(entry.text.contains("channel|>") || entry.text.contains("<think>") ? cleanModelText(entry.text) : entry.text,
                  selectable: false, networkImages: AppScope.of(context).current?.internetAllowed ?? false),
            ),
          for (var i = 0; i < entry.actions.length; i++) ActionCard(entry: entry, index: i),
          if (entry.cards.isNotEmpty)
            ResultCarousel(
              cards: entry.cards,
              loadImages: !(AppScope.of(context).current?.internetOff ?? false),
              onMore: () => AppScope.read(context).pendingInput.value = 'Such bitte weitere Ergebnisse dazu.',
            ),
          if (entry.error != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
                borderRadius: BorderRadius.circular(Ui.r),
              ),
              child: Row(children: [
                Icon(Icons.error_outline, color: scheme.error, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(entry.error!, style: TextStyle(color: scheme.onErrorContainer))),
              ]),
            ),
          if (entry.files.isNotEmpty) FileGallery(entry.files),
          if (!live && entry.sources.isNotEmpty) _Sources(entry.sources),
          if (!live && entry.cloudOffer && entry.via == null && AppScope.of(context).cloudProvider != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: AppScope.of(context).running ? null : () => AppScope.read(context).answerWithCloud(index),
                  icon: Icon(Icons.cloud_upload_outlined, size: 18, color: AppColors.of(context).blue),
                  label: Text('Mit ${AppScope.of(context).cloudProvider!.name} beantworten'),
                ),
              ),
            ),
          if (!live && (entry.text.isNotEmpty || entry.tokensPerSecond != null || entry.error != null))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (entry.via != null) ...[
                    StatusChip(entry.via!.startsWith('Lokal') ? entry.via!.substring(8) : entry.via!.split(' · ').take(2).join(' · '),
                        color: entry.via!.startsWith('Cloud')
                            ? AppColors.of(context).blue
                            : (entry.via!.startsWith('Lokal') ? AppColors.of(context).mint : AppColors.of(context).violet),
                        icon: entry.via!.startsWith('Cloud')
                            ? Icons.cloud_outlined
                            : (entry.via!.startsWith('Lokal') ? Icons.memory : Icons.dns_outlined),
                        dense: true),
                    const SizedBox(width: 8),
                  ],
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
          if (!live && (entry.text.isNotEmpty || entry.files.isNotEmpty) && entry.error == null)
            AiNotice(images: entry.files.any(isImageFile)),
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
      color: AppColors.of(context).panel,
      clipBehavior: Clip.antiAlias,
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
              : Icon(Icons.account_tree_outlined, color: scheme.primary, size: 20),
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
      fontFamily: Ui.mono,
      fontFamilyFallback: const ['Menlo', 'Courier'],
      fontSize: 11.5,
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
  ValueNotifier<String?>? _pending;
  String _lastHint = '';

  @override
  void initState() {
    super.initState();
    // Komplexe Eingabe → passendes Modell schon beim Tippen vorbereiten
    _ctrl.addListener(() {
      if (_ctrl.text == _lastHint) return;
      _lastHint = _ctrl.text;
      if (mounted) AppScope.read(context).typingHint(_ctrl.text);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = AppScope.read(context).pendingInput;
    if (!identical(p, _pending)) {
      _pending?.removeListener(_takePending);
      _pending = p..addListener(_takePending);
      WidgetsBinding.instance.addPostFrameCallback((_) => _takePending());
    }
  }

  /// Text aus „Teilen an Junels“ ins Eingabefeld übernehmen.
  void _takePending() {
    final t = _pending?.value;
    if (t == null || !mounted) return;
    _pending!.value = null;
    final existing = _ctrl.text.trim();
    _ctrl.text = existing.isEmpty ? t : '$existing\n$t';
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    _focus.requestFocus();
  }

  Future<void> _photo() async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await app.deviceBridge.takePhoto();
      if (path == null) return;
      final err = await app.addAttachment(path, path.split('/').last);
      if (err != null) messenger.showSnackBar(SnackBar(content: Text(err)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Kamera: $e')));
    }
  }

  void _useSuggestion(String text) {
    _ctrl.text = text;
    _ctrl.selection = TextSelection.collapsed(offset: text.length);
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _pending?.removeListener(_takePending);
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
    if (app.runningHere || app.status != EngineStatus.ready) return;
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
    final ready = app.canChat;
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
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
                  if (app.attachments.any((a) => isImageFile(a.name)) && !app.running)
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _ctrl,
                      builder: (context, v, _) => v.text.trim().isNotEmpty
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Wrap(spacing: 6, runSpacing: 4, children: [
                                for (final (label, text) in const [
                                  ('Zusammenfassen', 'Was steht auf dem Bild? Fasse es kurz zusammen.'),
                                  ('Text abschreiben', 'Schreib den Text auf dem Bild vollständig ab.'),
                                  ('Termin anlegen', 'Lies Datum, Uhrzeit, Ort und Titel vom Bild und trag den Termin in meinen Kalender ein.'),
                                  ('Kassenbon', 'Lies den Kassenbon: Geschäft, Datum, Positionen und Gesamtbetrag als Tabelle.'),
                                ])
                                  ActionChip(
                                    avatar: const Icon(Icons.auto_awesome, size: 16),
                                    label: Text(label),
                                    onPressed: () => _useSuggestion(text),
                                  ),
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
                              onDeleted: app.runningHere ? null : () => app.removeAttachment(a),
                            ),
                        ],
                      ),
                    ),
                  LayoutBuilder(builder: (context, box) {
                    final tools = <Widget>[
                      if (Platform.isAndroid)
                        PopupMenuButton<String>(
                          tooltip: 'Anhängen',
                          icon: const Icon(Icons.attach_file),
                          enabled: !app.runningHere,
                          onSelected: (v) => v == 'photo' ? _photo() : _attach(),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'photo',
                              child: ListTile(dense: true, leading: Icon(Icons.photo_camera_outlined), title: Text('Foto aufnehmen')),
                            ),
                            PopupMenuItem(
                              value: 'file',
                              child: ListTile(dense: true, leading: Icon(Icons.attach_file), title: Text('Datei oder Bild wählen')),
                            ),
                          ],
                        )
                      else
                        IconButton(
                          tooltip: 'Datei anhängen (PDF, Bilder, TXT, MD, CSV, JSON)',
                          icon: const Icon(Icons.attach_file),
                          onPressed: app.runningHere ? null : _attach,
                        ),
                      PopupMenuButton<String>(
                        tooltip: 'Prompts & Vorlagen',
                        icon: const Icon(Icons.bolt_outlined),
                        enabled: !app.runningHere,
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
                    final c = AppColors.of(context);
                    final field = TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 8,
                      enabled: ready,
                      textInputAction: TextInputAction.newline,
                      style: Theme.of(context).textTheme.bodyLarge,
                      decoration: InputDecoration(
                        hintText: !ready
                            ? 'Zuerst ein Modell laden oder einen Anbieter einrichten'
                            : (app.warming ? 'Modell wird vorbereitet … (du kannst schon schreiben)' : 'Frag Junels oder gib einen Auftrag …'),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                      ),
                    );
                    final sendButton = SizedBox(
                      width: 40,
                      height: 40,
                      child: app.runningHere
                          ? IconButton.filledTonal(
                              tooltip: 'Stopp',
                              icon: const Icon(Icons.stop_rounded, size: 20),
                              onPressed: app.stop,
                            )
                          : ValueListenableBuilder<TextEditingValue>(
                              valueListenable: _ctrl,
                              builder: (context, v, _) => IconButton.filled(
                                tooltip: 'Senden',
                                icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                                onPressed: ready && (v.text.trim().isNotEmpty || app.attachments.isNotEmpty) ? _send : null,
                              ),
                            ),
                    );
                    final route = app.routingLabel;
                    final switching = app.modelSwitching;
                    final composer = AnimatedBuilder(
                      animation: _focus,
                      builder: (context, child) => Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                              color: _focus.hasFocus ? c.mint.withValues(alpha: 0.55) : c.borderStrong, width: _focus.hasFocus ? 1.4 : 1),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.06),
                                blurRadius: 18,
                                offset: const Offset(0, 6)),
                          ],
                        ),
                        child: child,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          field,
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 0, 6, 6),
                            child: Row(children: [
                              for (final w in tools) IconTheme.merge(data: const IconThemeData(size: 21), child: w),
                              const Spacer(),
                              if (route != null && box.maxWidth >= 480)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: MonoText(route, size: 10.5, color: c.faint),
                                ),
                              sendButton,
                            ]),
                          ),
                        ],
                      ),
                    );
                    if (switching == null) return composer;
                    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                        child: Row(children: [
                          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: c.mint)),
                          const SizedBox(width: 8),
                          Expanded(child: MonoText(switching, size: 11, color: c.muted)),
                        ]),
                      ),
                      composer,
                    ]);
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


/// Freigabe-Karte: Entwurf (E-Mail, WhatsApp) mit „Senden“, „Bearbeiten“, „Verwerfen“.
class ActionCard extends StatefulWidget {
  const ActionCard({super.key, required this.entry, required this.index});
  final ChatEntry entry;
  final int index;

  @override
  State<ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<ActionCard> {
  bool _busy = false;
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final a = widget.entry.actions[widget.index];
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final mail = a['type'] == 'email';
    final who = (a['name'] ?? '').isNotEmpty ? a['name']! : ((a['to'] ?? '').isEmpty ? 'Empfänger fehlt' : a['to']!);
    final status = a['status'] ?? 'pending';
    final pending = status == 'pending';
    final direct = mail && app.settings.smtpReady && (a['to'] ?? '').contains('@');
    final body = a['body'] ?? '';
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: pending ? scheme.secondaryContainer.withValues(alpha: 0.55) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: pending ? scheme.secondary.withValues(alpha: 0.5) : scheme.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(mail ? Icons.mail_outline : Icons.chat_outlined, size: 20, color: scheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${mail ? 'E-Mail' : 'WhatsApp'} an $who', style: t.titleSmall, overflow: TextOverflow.ellipsis),
            ),
            if (!pending)
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text(switch (status) {
                  'sent' => 'Gesendet ✓',
                  'opened' => mail ? 'In Mail-App geöffnet' : 'In WhatsApp geöffnet',
                  'discarded' => 'Verworfen',
                  _ => status,
                }),
              ),
          ]),
          if (mail && (a['subject'] ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Betreff: ${a['subject']}', style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => setState(() => _open = !_open),
            child: Text(body, style: t.bodyMedium, maxLines: _open ? null : 4, overflow: _open ? null : TextOverflow.ellipsis),
          ),
          if ((a['error'] ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(a['error']!, style: t.bodySmall?.copyWith(color: scheme.error)),
            ),
          if (pending) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        final msg = await app.runAction(widget.entry, widget.index);
                        if (!context.mounted) return;
                        setState(() => _busy = false);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                      },
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(direct ? Icons.send : Icons.open_in_new, size: 18),
                label: Text(direct ? 'Senden' : (mail ? 'In Mail-App öffnen' : 'In WhatsApp öffnen')),
              ),
              OutlinedButton(onPressed: _busy ? null : () => _edit(context, app, a), child: const Text('Bearbeiten')),
              TextButton(
                onPressed: _busy ? null : () => app.updateAction(widget.entry, widget.index, {'status': 'discarded'}),
                child: const Text('Verwerfen'),
              ),
            ]),
            if (mail && !app.settings.smtpReady)
              TextButton(
                style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                onPressed: () => showMailAccountDialog(context),
                child: const Text('Direkt aus Junels senden einrichten'),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, AppController app, Map<String, String> a) async {
    final to = TextEditingController(text: a['to']);
    final subject = TextEditingController(text: a['subject']);
    final body = TextEditingController(text: a['body']);
    final mail = a['type'] == 'email';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(mail ? 'E-Mail bearbeiten' : 'Nachricht bearbeiten'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: to, decoration: InputDecoration(labelText: mail ? 'An (E-Mail-Adresse)' : 'An (Nummer)')),
              if (mail) TextField(controller: subject, decoration: const InputDecoration(labelText: 'Betreff')),
              const SizedBox(height: 8),
              TextField(controller: body, maxLines: 10, minLines: 4, decoration: const InputDecoration(border: OutlineInputBorder())),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Übernehmen')),
        ],
      ),
    );
    if (ok == true) {
      await app.updateAction(widget.entry, widget.index, {
        'to': to.text.trim(),
        if (to.text.trim() != (a['to'] ?? '')) 'name': '',
        'subject': subject.text,
        'body': body.text,
        'error': '',
      });
    }
  }
}

/// Mail-Konto für den Direktversand einrichten. Das Passwort landet im Tresor.
Future<void> showMailAccountDialog(BuildContext context) async {
  final app = AppScope.read(context);
  final st = app.settings;
  final user = TextEditingController(text: st.smtpUser);
  final pw = TextEditingController();
  final host = TextEditingController(text: st.smtpHost);
  final port = TextEditingController(text: '${st.smtpPort}');
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      void guess(String v) {
        final g = SmtpAccount.guessServer(v);
        if (g != null && host.text.isEmpty) {
          host.text = g.$1;
          port.text = '${g.$2}';
        }
      }

      return AlertDialog(
        title: const Text('E-Mails direkt senden'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Mit deinem Mail-Konto schickt Junels freigegebene E-Mails selbst ab – nur nach deinem Tipp auf „Senden“.'),
              const SizedBox(height: 8),
              TextField(controller: user, decoration: const InputDecoration(labelText: 'Deine E-Mail-Adresse'), onChanged: guess),
              TextField(
                controller: pw,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: st.smtpUser.isEmpty ? 'Passwort bzw. App-Passwort' : 'Neues Passwort (leer = behalten)',
                  helperText: 'Gmail, iCloud, Yahoo: App-Passwort im Konto erstellen (bei 2-Faktor-Anmeldung nötig).',
                  helperMaxLines: 2,
                ),
              ),
              Row(children: [
                Expanded(flex: 3, child: TextField(controller: host, decoration: const InputDecoration(labelText: 'Postausgang (SMTP)'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                const Icon(Icons.lock_outline, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      Vault.secure
                          ? 'Das Passwort liegt verschlüsselt im Tresor des Geräts (${Platform.isMacOS ? 'Schlüsselbund' : 'Android-Keystore'}). '
                              'Der Agent kann es nicht lesen.'
                          : 'Auf diesem System gibt es keinen Tresor – das Passwort gilt nur bis zum Beenden.',
                      style: Theme.of(ctx).textTheme.bodySmall),
                ),
              ]),
            ]),
          ),
        ),
        actions: [
          if (st.smtpReady)
            TextButton(
              onPressed: () async {
                await app.removeSmtp();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Entfernen'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () async {
              if (user.text.trim().isEmpty || host.text.trim().isEmpty) return;
              await app.saveSmtp(
                  host: host.text, port: int.tryParse(port.text) ?? 465, user: user.text, password: pw.text, from: user.text);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Speichern'),
          ),
        ],
      );
    }),
  );
}
