// Mitte: Streaming-Chat mit aufklappbarem Thought Log und Eingabefeld.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart' show modelCatalog, cleanModelText, ImapAccount, OutputView;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/skills.dart';
import '../state/smtp.dart';
import '../state/vault.dart';
import '../state/voice_service.dart';
import 'conversation_page.dart';
import 'file_views.dart';
import 'markdown_lite.dart';
import 'answer_views.dart';
import 'skills_page.dart';
import 'internet_menu.dart';
import 'quick_nav.dart';
import 'job_panel.dart';
import 'transcribe_page.dart' show openTranscriber;
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

  /// Folgt der Ansicht den neuen Zeilen? Nur der Nutzer schaltet das ab (nach oben scrollen)
  /// und wieder an (ganz nach unten scrollen oder Knopf „Zum Ende“).
  bool _stickToBottom = true;
  bool _userScrolling = false;

  bool _nearBottom() {
    if (!_scroll.hasClients) return true;
    final pos = _scroll.position;
    return pos.pixels >= pos.maxScrollExtent - 120;
  }

  bool _onScroll(ScrollNotification n) {
    if (n is UserScrollNotification) {
      if (n.direction == ScrollDirection.forward) {
        // nach oben: nicht mehr mitlaufen
        if (_stickToBottom) setState(() => _stickToBottom = false);
        _userScrolling = true;
      } else if (n.direction == ScrollDirection.idle) {
        _userScrolling = false;
        final near = _nearBottom();
        if (near != _stickToBottom) setState(() => _stickToBottom = near);
      } else {
        _userScrolling = true;
      }
    } else if (n is ScrollStartNotification && n.dragDetails != null) {
      _userScrolling = true;
    } else if (n is ScrollEndNotification) {
      _userScrolling = false;
      if (!_stickToBottom && _nearBottom()) setState(() => _stickToBottom = true);
    }
    return false;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool force = false}) {
    if (force) {
      _stickToBottom = true;
    } else if (!_stickToBottom || _userScrolling) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients || (_userScrolling && !force)) return;
      final pos = _scroll.position;
      if (pos.pixels < pos.maxScrollExtent) _scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final all = app.current?.entries ?? const <ChatEntry>[];
    final isFeed = app.current?.id == AppController.feedId;
    // Sammlung „Ergebnisse“: nach Herkunft filtern; Index bleibt der im Chat (für Wiederholen usw.)
    final filter = isFeed ? app.feedFilter.value : null;
    final idx = <int>[
      for (var i = 0; i < all.length; i++)
        if (filter == null || (all[i].originId ?? '').startsWith(filter)) i
    ];
    final entries = [for (final i in idx) all[i]];
    if (app.runningHere) _scrollToBottom();
    if (isFeed && app.feedUnread > 0) WidgetsBinding.instance.addPostFrameCallback((_) => app.markFeedSeen());

    // Sammlung „Ergebnisse“: Karten statt Chat-Verlauf, keine Eingabe (Nachfragen je Karte)
    if (isFeed) {
      return Column(children: [
        _FeedFilterBar(app: app),
        Expanded(child: _FeedView(key: ValueKey(app.feedFilter.value), app: app)),
      ]);
    }

    return Column(
      children: [
        Expanded(
          child: entries.isEmpty
              ? _EmptyState(app: app)
              : Stack(children: [
                  Positioned.fill(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: _onScroll,
                      child: SelectionArea(
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                          itemCount: entries.length + 1,
                          itemBuilder: (context, i) {
                            if (i == entries.length) {
                              return Center(
                                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: const _LiveStatus()),
                              );
                            }
                            final e = entries[i];
                            final live = app.runningHere && idx[i] == all.length - 1;
                            // Nur eine Reaktion (👍) – sitzt schon an deiner Nachricht
                            if (e.role == 'assistant' && !live && e.reaction != null && e.text.trim().isEmpty && e.error == null && e.actions.isEmpty) {
                              return SizedBox.shrink(key: ObjectKey(e));
                            }
                            final showOrigin = isFeed && e.origin != null && (i == 0 || entries[i - 1].originId != e.originId);
                            return Center(
                              key: ObjectKey(e),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 820),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                  if (showOrigin) _OriginHeader(entry: e),
                                  e.role == 'user' ? _UserBubble(entry: e, index: idx[i]) : _AssistantMessage(entry: e, live: live, index: idx[i]),
                                ]),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  if (!_stickToBottom)
                    Positioned(
                      bottom: 10,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: FloatingActionButton.small(
                          heroTag: null,
                          tooltip: 'Zum Ende',
                          onPressed: () => setState(() {
                            _stickToBottom = true;
                            if (_scroll.hasClients) {
                              _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
                            }
                          }),
                          child: const Icon(Icons.arrow_downward_rounded),
                        ),
                      ),
                    ),
                ]),
        ),
        _InputBar(onSent: () => _scrollToBottom(force: true)),
      ],
    );
  }
}

// ------------------------------------------------------ Sammlung „Ergebnisse“ als Karten

/// Ein Eintrag der Sammlung: Ergebnis eines Laufs oder ein ganzes Gespräch
class _FeedItem {
  _FeedItem(this.originId, this.origin);
  final String originId;
  final String origin;
  final List<ChatEntry> entries = [];
  ChatEntry? get answer => entries.where((e) => e.role == 'assistant').lastOrNull;
  DateTime get time => entries.last.time;
  bool get isVoice => originId.startsWith('voice:');
}

List<_FeedItem> _feedItems(List<ChatEntry> all, String? filter) {
  final items = <_FeedItem>[];
  final voice = <String, _FeedItem>{};
  ChatEntry? pendingQuestion;
  for (final e in all) {
    final id = e.originId ?? 'ohne';
    if (filter != null && !id.startsWith(filter)) continue;
    if (id.startsWith('voice:')) {
      final it = voice.putIfAbsent(id, () {
        final n = _FeedItem(id, e.origin ?? '🎙 Gespräch');
        items.add(n);
        return n;
      });
      it.entries.add(e);
      continue;
    }
    if (e.role == 'user') {
      pendingQuestion = e;
      continue;
    }
    final it = _FeedItem(id, e.origin ?? 'Ergebnis');
    if (pendingQuestion != null && pendingQuestion.originId == e.originId) it.entries.add(pendingQuestion);
    pendingQuestion = null;
    it.entries.add(e);
    items.add(it);
  }
  items.sort((a, b) => b.time.compareTo(a.time));
  return items;
}

class _FeedView extends StatefulWidget {
  const _FeedView({super.key, required this.app});
  final AppController app;

  @override
  State<_FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<_FeedView> {
  // Was vor dem Öffnen neu war, bleibt markiert, solange die Ansicht offen ist
  late final DateTime? _seen = widget.app.settings.feedSeen;
  final _open = <String>{};

  String _day(DateTime d) {
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff == 0) return 'Heute';
    if (diff == 1) return 'Gestern';
    if (diff < 7) return const ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'][d.weekday - 1];
    return '${d.day}.${d.month}.${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final items = _feedItems(app.feed.entries, app.feedFilter.value);
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: EmptyHint(
            icon: Icons.inbox_outlined,
            title: app.feedFilter.value == null ? 'Noch keine Ergebnisse' : 'Nichts in dieser Auswahl',
            text: 'Hier landet alles, was von selbst läuft: geplante Aufgaben, Abläufe, Beobachtungen und Gespräche.',
          ),
        ),
      );
    }
    final rows = <Widget>[];
    String? lastDay;
    for (final it in items) {
      final d = _day(it.time);
      if (d != lastDay) {
        rows.add(Padding(
          padding: EdgeInsets.fromLTRB(4, lastDay == null ? 4 : 18, 4, 8),
          child: Text(d, style: t.titleSmall?.copyWith(color: c.muted)),
        ));
        lastDay = d;
      }
      final key = '${it.originId}|${it.time.microsecondsSinceEpoch}';
      rows.add(_FeedCard(
        item: it,
        unread: _seen == null || it.time.isAfter(_seen),
        expanded: _open.contains(key),
        onToggle: () => setState(() => _open.contains(key) ? _open.remove(key) : _open.add(key)),
      ));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
        ),
      ],
    );
  }
}

class _FeedCard extends StatelessWidget {
  const _FeedCard({required this.item, required this.unread, required this.expanded, required this.onToggle});
  final _FeedItem item;
  final bool unread;
  final bool expanded;
  final VoidCallback onToggle;

  static (IconData, String) _kind(String id) => switch (id) {
        _ when id.startsWith('flow:') => (Icons.account_tree_outlined, 'Ablauf'),
        _ when id.startsWith('prompt:') => (Icons.schedule, 'Geplant'),
        _ when id.startsWith('voice:') => (Icons.graphic_eq, 'Gespräch'),
        _ when id.startsWith('watch:') => (Icons.radar, 'Beobachtung'),
        'mcp' => (Icons.electrical_services, 'Extern'),
        _ when id.startsWith('job:') => (Icons.explore_outlined, 'Web-Job'),
        _ => (Icons.inbox_outlined, 'Ergebnis'),
      };

  static String _title(String origin) => origin.replaceFirst(RegExp(r'^[^\p{L}\d]+', unicode: true), '').trim();

  /// Weiter im Chat: neuer Chat mit diesem Ergebnis als Zusammenhang
  void _continue(BuildContext context, AppController app) {
    final c = Conversation(id: newId(), title: 'Nachfrage: ${_title(item.origin)}');
    for (final e in item.entries) {
      c.entries.add(ChatEntry.fromJson(e.toJson()));
    }
    app.conversations.insert(0, c);
    app.current = c;
    app.refreshUi();
  }

  Future<void> _rerun(BuildContext context, AppController app) async {
    final id = item.originId;
    if (id.startsWith('flow:')) {
      final wf = app.flows.flows.where((f) => f.id == id.substring(5)).firstOrNull;
      if (wf != null) unawaited(app.flows.run(wf));
    } else if (id.startsWith('prompt:')) {
      final p = app.prompts.where((p) => p.id == id.substring(7)).firstOrNull;
      if (p != null) unawaited(app.runPrompt(p));
    } else if (id.startsWith('job:')) {
      final j = app.webJobs.byId(id.substring(4));
      if (j != null) {
        final skill = j.skillId == null ? null : app.skills.byId(j.skillId!);
        app.webJobs.start(goal: j.goal, title: j.title, skill: skill, output: j.output);
      }
    }
  }

  bool _canRerun(AppController app) {
    final id = item.originId;
    if (id.startsWith('flow:')) return app.flows.flows.any((f) => f.id == id.substring(5));
    if (id.startsWith('prompt:')) return app.prompts.any((p) => p.id == id.substring(7));
    if (id.startsWith('job:')) return app.webJobs.byId(id.substring(4))?.finished ?? false;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final (icon, kind) = _kind(item.originId);
    final a = item.answer;
    final live = app.running && app.runningConvId == AppController.feedId && a != null && identical(a, app.feed.entries.lastOrNull);
    final err = a?.error;
    final time = '${item.time.hour.toString().padLeft(2, '0')}:${item.time.minute.toString().padLeft(2, '0')}';
    final tint = err != null ? c.red : (item.isVoice ? c.violet : (item.originId.startsWith('flow:') ? c.amber : c.mint));
    final text = a == null ? '' : cleanModelText(a.text);
    final long = text.length > 280 || '\n'.allMatches(text.trim()).length >= 5 || (a?.cards.isNotEmpty ?? false) || (a?.steps.isNotEmpty ?? false) || (a?.actions.isNotEmpty ?? false);

    Widget body;
    if (item.isVoice) {
      // Gespräch: Frage und Antwort kompakt untereinander
      final pairs = item.entries.where((e) => e.text.trim().isNotEmpty || e.reaction != null).toList();
      final shown = expanded ? pairs : pairs.skip(pairs.length > 4 ? pairs.length - 4 : 0).toList();
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!expanded && pairs.length > 4)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('… ${pairs.length - 4} frühere', style: t.bodySmall)),
        for (final e in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(e.role == 'user' ? Icons.mic_none : Icons.auto_awesome, size: 16, color: e.role == 'user' ? c.muted : tint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.text.trim().isEmpty ? (e.reaction ?? '') : cleanModelText(e.text),
                  maxLines: expanded ? null : 3,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                  style: e.role == 'user' ? t.bodyMedium?.copyWith(color: c.muted) : t.bodyMedium,
                ),
              ),
            ]),
          ),
      ]);
    } else if (expanded && a != null) {
      final i = app.feed.entries.indexOf(a);
      body = _AssistantMessage(entry: a, live: live, index: i);
    } else if (err != null) {
      body = Text(err, style: t.bodyMedium?.copyWith(color: c.red));
    } else if (live && text.isEmpty) {
      body = Row(children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text('läuft …', style: t.bodyMedium),
      ]);
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (item.entries.first.role == 'user' && item.entries.first.text.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('„${item.entries.first.text.trim()}“',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: c.muted)),
          ),
        // Vorschau: oben abgeschnitten, weich ausgeblendet
        ShaderMask(
          shaderCallback: (r) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Colors.white, long ? Colors.transparent : Colors.white],
            stops: const [0, 0.7, 1],
          ).createShader(r),
          blendMode: BlendMode.dstIn,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ClipRect(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: MarkdownLite(text, selectable: false),
              ),
            ),
          ),
        ),
        if ((a?.cards.isNotEmpty ?? false) || (a?.files.isNotEmpty ?? false))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              if (a!.cards.isNotEmpty) StatusChip('${a.cards.length} Treffer', color: c.blue, icon: Icons.view_carousel_outlined, dense: true),
              for (final f in a.files.take(3))
                StatusChip(f.split(RegExp(r'[/\\]')).last, color: c.muted, icon: Icons.insert_drive_file_outlined, dense: true),
            ]),
          ),
      ]);
    }

    // Web-Job: Fortschritt oben, Ergebnis (sobald da) darunter
    if (item.originId.startsWith('job:')) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        JobPanel(jobId: item.originId.substring(4)),
        if (text.isNotEmpty) ...[const SizedBox(height: 8), body],
      ]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
        borderColor: unread ? tint.withValues(alpha: 0.45) : null,
        onTap: expanded ? null : onToggle,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: tint.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: tint),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_title(item.origin), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                Text('$kind · $time${err != null ? ' · Fehler' : ''}', style: t.labelSmall?.copyWith(color: err != null ? c.red : c.faint)),
              ]),
            ),
            if (unread)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Container(width: 8, height: 8, decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
              ),
            PopupMenuButton<String>(
              tooltip: 'Mehr',
              icon: Icon(Icons.more_horiz, color: c.muted),
              onSelected: (v) async {
                switch (v) {
                  case 'chat':
                    _continue(context, app);
                  case 'again':
                    await _rerun(context, app);
                  case 'copy':
                    await Clipboard.setData(ClipboardData(
                        text: item.entries.map((e) => cleanModelText(e.text)).where((x) => x.trim().isNotEmpty).join('\n\n')));
                  case 'remove':
                    for (final e in item.entries) {
                      app.feed.entries.remove(e);
                    }
                    await app.storage.saveConversation(app.feed);
                    app.refreshUi();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'chat', child: ListTile(leading: Icon(Icons.forum_outlined), title: Text('Im Chat weiterführen'))),
                if (_canRerun(app))
                  const PopupMenuItem(value: 'again', child: ListTile(leading: Icon(Icons.replay), title: Text('Nochmal ausführen'))),
                const PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.copy), title: Text('Kopieren'))),
                const PopupMenuItem(value: 'remove', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Entfernen'))),
              ],
            ),
          ]),
          const SizedBox(height: 10),
          Padding(padding: const EdgeInsets.only(right: 8), child: body),
          Row(children: [
            if (long || item.isVoice && item.entries.length > 4 || expanded)
              TextButton.icon(
                onPressed: onToggle,
                icon: Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
                label: Text(expanded ? 'Weniger' : 'Ganz anzeigen'),
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _continue(context, app),
              icon: Icon(Icons.reply, size: 18, color: scheme.primary),
              label: const Text('Nachfragen'),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------ Sammlung „Ergebnisse“ (Filter)

/// Herkunft eines Ergebnisses (Ablauf, geplante Aufgabe, Gespräch …) über dem Eintrag
class _OriginHeader extends StatelessWidget {
  const _OriginHeader({required this.entry});
  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final d = entry.time;
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final when = d.year == now.year && d.month == now.month && d.day == now.day
        ? '${two(d.hour)}:${two(d.minute)}'
        : '${d.day}.${d.month}. ${two(d.hour)}:${two(d.minute)}';
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 2),
      child: Row(children: [
        Expanded(child: Divider(color: c.border, height: 1)),
        const SizedBox(width: 8),
        Flexible(
          child: Text('${entry.origin} · $when',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: t.labelMedium?.copyWith(color: c.faint)),
        ),
        const SizedBox(width: 8),
        Expanded(child: Divider(color: c.border, height: 1)),
      ]),
    );
  }
}

/// Filter der Sammlung nach Herkunft
class _FeedFilterBar extends StatelessWidget {
  const _FeedFilterBar({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final entries = app.feed.entries;
    // Herkünfte in der Reihenfolge des letzten Auftretens (neueste zuerst)
    final seen = <String, String>{};
    for (final e in entries.reversed) {
      final id = e.originId;
      if (id == null || e.origin == null || seen.containsKey(id)) continue;
      seen[id] = e.origin!;
    }
    int count(String prefix) => entries.where((e) => e.role == 'assistant' && (e.originId ?? '').startsWith(prefix)).length;
    final kinds = <(String, String)>[
      ('job:', '🧭 Web-Jobs'),
      ('flow:', '⚙ Abläufe'),
      ('prompt:', '⏱ Geplant'),
      ('voice:', '🎙 Gespräche'),
      ('watch:', '👁 Beobachtungen'),
      ('mcp', '🔌 Extern'),
    ].where((k) => count(k.$1) > 0).toList();
    final f = app.feedFilter.value;
    Widget chip(String label, String? value) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            visualDensity: VisualDensity.compact,
            label: Text(label),
            selected: f == value,
            onSelected: (_) {
              app.feedFilter.value = value;
              app.refreshUi();
            },
          ),
        );
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        children: [
          chip('Alle', null),
          for (final k in kinds) chip(k.$2, k.$1),
          // einzelne Abläufe/Aufgaben (die neuesten), wenn es mehrere gibt
          if (seen.length > 1)
            for (final e in seen.entries.where((e) => !e.key.startsWith('voice:')).take(8)) chip(e.value, e.key),
        ],
      ),
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
                        Text(rest > 0 ? 'Weitere laden\n($rest)' : 'Mehr suchen',
                            textAlign: TextAlign.center, style: t.labelLarge?.copyWith(color: scheme.primary)),
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
                      width: 40, height: 40, errorBuilder: (_, __, ___) => Icon(Icons.public, size: 40, color: scheme.outline));
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
                                loadingBuilder: (_, child, p) =>
                                    p == null ? child : const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
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
                            Text(c['title'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                            if (note.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Expanded(
                                child: Text(note, maxLines: 4, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
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
                            child: Text(host, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
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
          child: Text('$label …$el', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
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
            Stack(clipBehavior: Clip.none, children: [
            Container(
              margin: EdgeInsets.only(bottom: entry.reaction == null ? 0 : 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.of(context).raised,
                border: Border.all(color: AppColors.of(context).border),
                borderRadius: BorderRadius.circular(18).copyWith(bottomRight: const Radius.circular(6)),
              ),
              child: Text.rich(
                  TextSpan(children: [
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
                  ]),
                  style: Theme.of(context).textTheme.bodyLarge),
            ),
            if (entry.reaction != null)
              Positioned(
                left: -6,
                bottom: 0,
                child: Tooltip(
                  message: '${AppScope.of(context).settings.agentName} hat reagiert',
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.of(context).border),
                    ),
                    child: Text(entry.reaction!, style: const TextStyle(fontSize: 15)),
                  ),
                ),
              ),
            ]),
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
    final cleaned = entry.text.contains("channel|>") || entry.text.contains("<think>") ? cleanModelText(entry.text) : entry.text;
    final shaped = !live && entry.view != null && entry.view != OutputView.text;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8, right: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (entry.steps.isNotEmpty) _ThoughtLog(steps: entry.steps, live: live && entry.text.isEmpty),
          // Web-Job: Fortschritt live (läuft unabhängig vom Chat weiter)
          if ((entry.originId ?? '').startsWith('job:'))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(padding: const EdgeInsets.fromLTRB(12, 10, 8, 4), child: JobPanel(jobId: entry.originId!.substring(4))),
            ),
          if (waiting)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Verarbeite Prompt …'),
              ]),
            ),
          if (entry.text.isNotEmpty && shaped)
            AnswerBody(
              entry: entry,
              text: cleaned,
              networkImages: AppScope.of(context).current?.internetAllowed ?? false,
              loadImages: !(AppScope.of(context).current?.internetOff ?? false),
            )
          else if (entry.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: MarkdownLite(cleaned, selectable: false, networkImages: AppScope.of(context).current?.internetAllowed ?? false),
            ),
          for (var i = 0; i < entry.actions.length; i++) ActionCard(entry: entry, index: i),
          if (entry.cards.isNotEmpty && !(shaped && (entry.view == OutputView.cards || entry.view == OutputView.table)))
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
          if (!live &&
              entry.cloudOffer &&
              (entry.via == null || entry.via!.startsWith('Lokal')) &&
              AppScope.of(context).escalationProvider(AppScope.of(context).current) != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: AppScope.of(context).running ? null : () => AppScope.read(context).answerWithCloud(index),
                  icon: Icon(Icons.cloud_upload_outlined, size: 18, color: AppColors.of(context).blue),
                  label: Text('Mit ${AppScope.of(context).escalationProvider(AppScope.of(context).current)!.name} beantworten'),
                ),
              ),
            ),
          if (!live && (entry.text.isNotEmpty || entry.tokensPerSecond != null || entry.error != null))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Chips und Zeiten brechen auf schmalen Handys um, statt die Zeile zu sprengen
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (entry.skill != null) ...[
                          StatusChip('Skill: ${entry.skill}', color: AppColors.of(context).amber, icon: Icons.auto_awesome, dense: true),
                        ],
                        if (entry.via != null) ...[
                          StatusChip(entry.via!.startsWith('Lokal') ? entry.via!.substring(8) : entry.via!.split(' · ').take(2).join(' · '),
                              color: entry.via!.startsWith('Cloud')
                                  ? AppColors.of(context).blue
                                  : (entry.via!.startsWith('Lokal') ? AppColors.of(context).mint : AppColors.of(context).violet),
                              icon:
                                  entry.via!.startsWith('Cloud') ? Icons.cloud_outlined : (entry.via!.startsWith('Lokal') ? Icons.memory : Icons.dns_outlined),
                              dense: true),
                        ],
                        if (entry.durationMs != null || entry.tokensPerSecond != null)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            if (entry.truncated) Text('gekürzt · ', style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                            if (entry.durationMs != null) ...[
                              Icon(Icons.timer_outlined, size: 13, color: scheme.onSurfaceVariant),
                              const SizedBox(width: 3),
                              Text(formatDuration(entry.durationMs!), style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                              if (entry.tokensPerSecond != null) Text(' · ', style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                            ],
                            if (entry.tokensPerSecond != null)
                              Text('${entry.tokensPerSecond!.toStringAsFixed(1)} Tokens/s', style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                          ]),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Neu generieren',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    icon: const Icon(Icons.refresh),
                    onPressed: AppScope.of(context).running ? null : () => AppScope.read(context).regenerate(index),
                  ),
                  if (entry.text.isNotEmpty) _SpeakButton(entry: entry),
                  if (entry.text.isNotEmpty)
                    PopupMenuButton<String>(
                      tooltip: 'Mehr',
                      iconSize: 16,
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_horiz),
                      onSelected: (v) {
                        if (v == 'copy') {
                          Clipboard.setData(ClipboardData(text: entry.text));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kopiert'), duration: Duration(seconds: 1)));
                        } else if (v == 'skill') {
                          _saveAsSkill(context, index);
                        } else if (v.startsWith('view:')) {
                          AppScope.read(context).reshapeAnswer(index, v.substring(5));
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'copy', child: ListTile(dense: true, leading: Icon(Icons.copy, size: 20), title: Text('Antwort kopieren'))),
                        const PopupMenuItem(
                            value: 'skill', child: ListTile(dense: true, leading: Icon(Icons.auto_awesome, size: 20), title: Text('Als Skill speichern'))),
                        const PopupMenuDivider(),
                        for (final v in const [
                          OutputView.text,
                          OutputView.cards,
                          OutputView.table,
                          OutputView.list,
                          OutputView.steps,
                          OutputView.excel,
                          OutputView.word
                        ])
                          PopupMenuItem(
                            value: 'view:$v',
                            enabled: !(entry.view == v || (v == OutputView.text && entry.view == null)),
                            child: ListTile(
                                dense: true,
                                leading: Icon(outputViewIcon(v), size: 20),
                                title: Text(OutputView.isFile(v) ? 'Als ${OutputView.labels[v]}-Datei' : 'Als ${OutputView.labels[v]} zeigen')),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          if (!live && (entry.text.isNotEmpty || entry.files.isNotEmpty) && entry.error == null) AiNotice(images: entry.files.any(isImageFile)),
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
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Adresse kopiert: ${r.url}'), duration: const Duration(seconds: 2)));
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
            live ? 'Denkt nach … Schritt ${steps.length}' : 'Denkschritte: ${steps.length} · $tools Tool-Aufruf${tools == 1 ? '' : 'e'}',
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
                if (step.thought.isNotEmpty) Text(step.thought, style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
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
                      if (step.args != null && step.args!.isNotEmpty) Text(_shortArgs(step.args!), style: mono),
                    ],
                  ),
                ],
                if (step.observation != null)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(8),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: step.isError ? scheme.errorContainer.withValues(alpha: 0.5) : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      step.observation!.length > 600 ? '${step.observation!.substring(0, 600)} …' : step.observation!,
                      style: mono,
                    ),
                  ),
                if (step.durationMs > 0) Text('${step.durationMs} ms', style: t.labelSmall?.copyWith(color: scheme.outline)),
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
                    builder: (context, s, _) => Text('0:${s.toString().padLeft(2, '0')}', style: Theme.of(context).textTheme.labelSmall),
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
    if ((Platform.isMacOS || Platform.isIOS) && e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _send() {
    final app = AppScope.read(context);
    if (!app.canChat) return;
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    // Läuft gerade eine Antwort hier, geht der Text als Kommentar an den Agenten
    if (app.runningHere && app.attachments.isNotEmpty) return;
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
            ? SnackBarAction(
                label: 'Laden',
                onPressed: () {
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
                  // Skills: „/“ tippen zeigt passende Skills
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _ctrl,
                    builder: (context, v, _) {
                      // „/“ am Anfang oder mitten im Satz (das Wort vor dem Cursor)
                      final before = v.selection.isValid ? v.text.substring(0, v.selection.baseOffset.clamp(0, v.text.length)) : v.text;
                      final m = RegExp(r'(?:^|\s)/([a-z0-9äöüß-]*)$', caseSensitive: false).firstMatch(before);
                      if (m == null) return const SizedBox.shrink();
                      final q = m.group(1)!.toLowerCase();
                      final hits = [
                        for (final s in app.skills.enabled)
                          if (s.command.startsWith(q) || s.name.toLowerCase().contains(q)) s
                      ];
                      if (hits.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SizedBox(
                          height: 40,
                          child: ListView(scrollDirection: Axis.horizontal, children: [
                            for (final s in hits.take(12))
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ActionChip(
                                  avatar: Icon(skillIcon(s.icon), size: 16),
                                  label: Text('/${s.command} · ${s.name}'),
                                  onPressed: () {
                                    // nur das angefangene /wort ersetzen – der restliche Satz bleibt
                                    final start = before.length - m.group(1)!.length - 1;
                                    final t = '${v.text.substring(0, start)}/${s.command} ${v.text.substring(before.length).trimLeft()}';
                                    _ctrl.text = t;
                                    _ctrl.selection = TextSelection.collapsed(offset: start + s.command.length + 2);
                                    _focus.requestFocus();
                                  },
                                ),
                              ),
                          ]),
                        ),
                      );
                    },
                  ),
                  // Anhänge und Vorschläge in EINER wischbaren Zeile – sonst belegen sie den halben Bildschirm
                  if (app.attachments.isNotEmpty)
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _ctrl,
                      builder: (context, v, _) {
                        final suggest = app.attachments.any((a) => isImageFile(a.name)) && !app.running && v.text.trim().isEmpty;
                        String short(String n) => n.length > 22 ? '${n.substring(0, 12)}…${n.substring(n.length - 8)}' : n;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: SizedBox(
                            height: 40,
                            child: ListView(scrollDirection: Axis.horizontal, children: [
                              for (final a in app.attachments)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InputChip(
                                    visualDensity: VisualDensity.compact,
                                    avatar: a.path != null && isImageFile(a.name)
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(4),
                                            child: Image.file(File(a.path!), width: 24, height: 24, fit: BoxFit.cover, cacheWidth: 64),
                                          )
                                        : Icon(a.name.toLowerCase().endsWith('.pdf') ? Icons.picture_as_pdf_outlined : Icons.description_outlined, size: 16),
                                    label: Text(short(a.name)),
                                    tooltip: a.name,
                                    onDeleted: app.runningHere ? null : () => app.removeAttachment(a),
                                  ),
                                ),
                              if (suggest) ...[
                                const VerticalDivider(width: 12, indent: 8, endIndent: 8),
                                for (final (label, text) in const [
                                  ('Zusammenfassen', 'Was steht auf dem Bild? Fasse es kurz zusammen.'),
                                  ('Text abschreiben', 'Schreib den Text auf dem Bild vollständig ab.'),
                                  ('Termin anlegen', 'Lies Datum, Uhrzeit, Ort und Titel vom Bild und trag den Termin in meinen Kalender ein.'),
                                  ('Kassenbon', 'Lies den Kassenbon: Geschäft, Datum, Positionen und Gesamtbetrag als Tabelle.'),
                                ])
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: ActionChip(
                                      visualDensity: VisualDensity.compact,
                                      avatar: const Icon(Icons.auto_awesome, size: 16),
                                      label: Text(label),
                                      onPressed: () => _useSuggestion(text),
                                    ),
                                  ),
                              ],
                            ]),
                          ),
                        );
                      },
                    ),
                  // KI-Weiche, Internet und Schnellmenü direkt über der Eingabe
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: const [
                            AiModeMenu(),
                            SizedBox(width: 6),
                            InternetMenu(),
                            SizedBox(width: 6),
                            OutputViewMenu(),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 6),
                      PillIconButton(icon: Icons.apps_rounded, tooltip: 'Schnellmenü', onPressed: () => showQuickNav(context)),
                    ]),
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
                        tooltip: 'Skills, Prompts & Vorlagen',
                        icon: const Icon(Icons.bolt_outlined),
                        enabled: !app.runningHere,
                        onSelected: (v) {
                          if (v == '__save__') {
                            editPrompt(context, initialText: _ctrl.text);
                            return;
                          }
                          if (v == '__mitschrift__') {
                            openTranscriber(context);
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
                          const PopupMenuItem(
                            value: '__mitschrift__',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.record_voice_over_outlined, size: 20),
                              title: Text('Mitschrift starten'),
                              subtitle: Text('Gespräch mitschreiben, danach auswerten'),
                            ),
                          ),
                          const PopupMenuDivider(),
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
                          for (final s in app.skills.enabled.take(10))
                            PopupMenuItem(
                              value: '/${s.command} ',
                              child: ListTile(
                                dense: true,
                                leading: Icon(skillIcon(s.icon), size: 20),
                                title: Text(s.name),
                                subtitle: Text('/${s.command}'),
                              ),
                            ),
                          const PopupMenuDivider(),
                          for (final (label, text) in promptPresets) PopupMenuItem(value: text, child: Text(label)),
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
                            : app.runningHere
                                ? 'Kommentar ergänzen – der Agent berücksichtigt ihn sofort …'
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
                          ? ValueListenableBuilder<TextEditingValue>(
                              valueListenable: _ctrl,
                              builder: (context, v, _) => v.text.trim().isEmpty
                                  ? IconButton.filledTonal(
                                      tooltip: 'Stopp',
                                      icon: const Icon(Icons.stop_rounded, size: 20),
                                      onPressed: app.stop,
                                    )
                                  : IconButton.filled(
                                      tooltip: 'Kommentar an den laufenden Auftrag',
                                      icon: const Icon(Icons.add_comment_outlined, size: 19),
                                      onPressed: _send,
                                    ),
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
                          border: Border.all(color: _focus.hasFocus ? c.mint.withValues(alpha: 0.55) : c.borderStrong, width: _focus.hasFocus ? 1.4 : 1),
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
    final appAct = a['type'] == 'app';
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
            Icon(appAct ? Icons.apps : (mail ? Icons.mail_outline : Icons.chat_outlined), size: 20, color: scheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(appAct ? 'App: ${a['app'] ?? ''}' : '${mail ? 'E-Mail' : 'WhatsApp'} an $who', style: t.titleSmall, overflow: TextOverflow.ellipsis),
            ),
            if (!pending)
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text(switch (status) {
                  'sent' => appAct ? 'Ausgeführt ✓' : 'Gesendet ✓',
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
                    : Icon(appAct ? Icons.play_arrow : (direct ? Icons.send : Icons.open_in_new), size: 18),
                label: Text(appAct ? 'Ausführen' : (direct ? 'Senden' : (mail ? 'In Mail-App öffnen' : 'In WhatsApp öffnen'))),
              ),
              if (!appAct) OutlinedButton(onPressed: _busy ? null : () => _edit(context, app, a), child: const Text('Bearbeiten')),
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
  final imapHost = TextEditingController(text: st.imapHost);
  final imapPort = TextEditingController(text: '${st.imapPort}');
  var imapOn = st.imapEnabled;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      void guess(String v) {
        final g = SmtpAccount.guessServer(v);
        if (g != null && host.text.isEmpty) {
          host.text = g.$1;
          port.text = '${g.$2}';
        }
        if (imapHost.text.isEmpty || imapHost.text == ImapAccount.guessHost(st.smtpUser, smtpHost: st.smtpHost)) {
          imapHost.text = ImapAccount.guessHost(v, smtpHost: host.text) ?? '';
        }
      }

      return AlertDialog(
        title: const Text('Mail-Konto'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Mit deinem Mail-Konto schickt Junels freigegebene E-Mails selbst ab – nur nach deinem Tipp auf „Senden“ – '
                  'und kann auf Wunsch deinen Posteingang ansehen.'),
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
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Posteingang lesen'),
                subtitle: const Text('Nur Absender, Betreff, Datum und Status – für „Was ist liegengeblieben?“ und Fragen zu Mails. '
                    'Junels ändert nichts im Postfach.'),
                value: imapOn,
                onChanged: (v) => setS(() {
                  imapOn = v;
                  if (v && imapHost.text.isEmpty) imapHost.text = ImapAccount.guessHost(user.text, smtpHost: host.text) ?? '';
                }),
              ),
              if (imapOn)
                Row(children: [
                  Expanded(flex: 3, child: TextField(controller: imapHost, decoration: const InputDecoration(labelText: 'Posteingang (IMAP)'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: imapPort, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number)),
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
              await app.saveSmtp(host: host.text, port: int.tryParse(port.text) ?? 465, user: user.text, password: pw.text, from: user.text);
              await app.saveImap(enabled: imapOn, host: imapHost.text, port: int.tryParse(imapPort.text) ?? 993);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Speichern'),
          ),
        ],
      );
    }),
  );
}

/// „Als Skill speichern“: aus Frage + benutzten Werkzeugen einen Skill-Entwurf machen und im Editor öffnen.
void _saveAsSkill(BuildContext context, int index) {
  final app = AppScope.read(context);
  final conv = app.current;
  if (conv == null || index <= 0 || index >= conv.entries.length) return;
  final answer = conv.entries[index];
  final question = conv.entries.take(index).lastWhere((e) => e.role == 'user', orElse: () => ChatEntry(role: 'user')).text.trim();
  final used = <String>[];
  for (final s in answer.steps) {
    final tool = s.tool;
    if (tool != null && tool.isNotEmpty && !used.contains(tool) && app.tools.any((t) => t.name == tool)) used.add(tool);
  }
  final titles = {for (final t in app.tools) t.name: t.title};
  final q = question.replaceFirst(RegExp(r'^/[a-z0-9äöüß-]+\s*', caseSensitive: false), '');
  final name = conv.title == 'Neuer Chat' ? (q.length > 30 ? q.substring(0, 30) : q) : conv.title.replaceAll('…', '');
  final steps = [
    for (var i = 0; i < used.length; i++) '${i + 1}. ${titles[used[i]] ?? used[i]} nutzen',
    '${used.length + 1}. Ergebnis so aufbereiten wie im Beispiel unten',
  ].join('\n');
  final created = answer.files.isNotEmpty || used.any((u) => u.startsWith('create_'));
  final draft = Skill(
    id: 'u-${DateTime.now().microsecondsSinceEpoch}',
    name: name.trim(),
    when: 'Wenn ich so etwas möchte wie: „${q.length > 120 ? '${q.substring(0, 120)}…' : q}“',
    instructions: steps,
    tools: used,
    requiredTool: created ? used.firstWhere((u) => u.startsWith('create_'), orElse: () => '') : '',
    knowledge: 'Beispiel-Frage: $q\n\nBeispiel-Ergebnis:\n${answer.text.length > 1200 ? '${answer.text.substring(0, 1200)}…' : answer.text}',
  );
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => SkillEditor(draft: draft)));
}
