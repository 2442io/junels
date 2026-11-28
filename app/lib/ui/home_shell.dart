// Three-Pane-Layout mit drei Breakpoints (SRS Abschnitt 3):
//   < 900 px   Smartphone / Tablet hochkant: Sidebar und Inspector als Drawer
//   900–1200   Tablet quer: Sidebar als Drawer, Inspector fest rechts
//   ≥ 1200     Mac / großes Tablet: alle drei Bereiche sichtbar

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'browser_panel.dart';
import 'chat_view.dart';
import 'guide_card.dart';
import 'inspector.dart';
import 'prompt_editor.dart';
import 'conversation_page.dart';
import 'sidebar.dart';
import 'system_check.dart';
import 'nav.dart';
import 'self_test_page.dart';
import 'watchlist_page.dart';
import 'flows_page.dart';
import '../state/notifications.dart';
import 'notify_style.dart';
import 'theme.dart';
import 'transcribe_page.dart';
import '../l10n.dart';

/// Fragt, ob der Agent ins Internet darf.
Future<NetworkChoice> askNetworkConsent(BuildContext context, String purpose) async {
  final r = await showDialog<NetworkChoice>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.public),
      title: Text(tr('Internetzugriff erlauben?')),
      content: Text(('Der Agent möchte ins Internet:\n\n$purpose\n\n' + tr('Dabei wird nur diese Anfrage gesendet. Das Sprachmodell selbst läuft weiter lokal.\n\n') + tr('„Einmal“ gilt für diese Frage, „Ganzer Chat“ für alle weiteren Fragen in diesem Chat.'))),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        Row(children: [
          Expanded(
            child: TextButton(onPressed: () => Navigator.pop(ctx, NetworkChoice.deny), child: Text(tr('Nein'))),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, NetworkChoice.once),
                child: Text(tr('Einmal'), textAlign: TextAlign.center)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: FilledButton(
                onPressed: () => Navigator.pop(ctx, NetworkChoice.chat),
                child: Text(tr('Ganzer Chat'), textAlign: TextAlign.center)),
          ),
        ]),
      ],
    ),
  );
  return r ?? NetworkChoice.deny;
}

/// Fragt, ob eine Frage an den Cloud-Anbieter gehen darf.
Future<NetworkChoice> askCloudConsent(BuildContext context, String reason) async {
  final c = AppColors.of(context);
  final r = await showDialog<NetworkChoice>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.cloud_upload_outlined, color: c.blue),
      title: Text(tr('Cloud-Anbieter verwenden?')),
      content: Text(('$reason\n\n' + tr('Dabei gehen deine Frage, der bisherige Chatverlauf und gefundene Inhalte an den Anbieter.\n\n') + tr('„Einmal“ gilt für diese Frage, „Ganzer Chat“ für alle weiteren Fragen in diesem Chat.'))),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        Row(children: [
          Expanded(child: TextButton(onPressed: () => Navigator.pop(ctx, NetworkChoice.deny), child: Text(tr('Nein')))),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, NetworkChoice.once),
                child: Text(tr('Einmal'), textAlign: TextAlign.center)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: FilledButton(
                onPressed: () => Navigator.pop(ctx, NetworkChoice.chat),
                child: Text(tr('Ganzer Chat'), textAlign: TextAlign.center)),
          ),
        ]),
      ],
    ),
  );
  return r ?? NetworkChoice.deny;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffold = GlobalKey<ScaffoldState>();
  /// null = automatisch: nur zeigen, wenn der Chat Artefakte hat
  bool? _inspectorChoice;
  bool get _inspectorVisible => _inspectorChoice ?? (AppScope.read(context).current?.artifacts.isNotEmpty ?? false);
  bool _focus = false; // Fokus-Modus: nur der Chat
  bool _firstRunHandled = false;

  void _onReady(AppController app) {
    if (_firstRunHandled) return;
    _firstRunHandled = true;
    app.consentHandler = (purpose) => askNetworkConsent(context, purpose);
    app.cloudConsentHandler = (reason) => askCloudConsent(context, reason);
    app.deviceBridge.confirmHandler = (title, detail) => _confirm(title, detail);
    app.choiceHandler = (title, detail) => _choice(title, detail);
    // /mitschrift (oder Schnellmenü): Aufnahme-Seite öffnen
    app.openTranscriberRequest.addListener(() {
      if (mounted) openTranscriber(context);
    });
    app.pendingLaunch.addListener(() => _launch(app));
    if (app.pendingLaunch.value != null) WidgetsBinding.instance.addPostFrameCallback((_) => _launch(app));
    if (app.needsSystemCheck) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openSystemCheck(context);
      });
    }
  }

  Future<bool> _confirm(String title, String detail) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.help_outline),
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Nein'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Ja, ausführen'))),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Freigabe je Website: Nein / Einmal / Immer auf dieser Seite
  Future<String> _choice(String title, String detail) async {
    final r = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.verified_user_outlined),
        title: Text(title),
        content: Text(detail),
        actionsOverflowButtonSpacing: 4,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'no'), child: Text(tr('Nein'))),
          OutlinedButton(onPressed: () => Navigator.pop(ctx, 'always'), child: Text(tr('Hier immer'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'once'), child: Text(tr('Ja, einmal'))),
        ],
      ),
    );
    return r ?? 'no';
  }

  /// Schnellstart vom Startbildschirm / Dock-Menü.
  void _launch(AppController app) {
    final a = app.pendingLaunch.value;
    if (a == null || !mounted) return;
    app.pendingLaunch.value = null;
    if (a == 'conversation') {
      openConversation(context);
    } else if (a == 'selftest') {
      openSelfTest(context);
    } else if (a.startsWith('watch:') && app.watchlist.items.any((w) => w.id == a.substring(6))) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => WatchDetailPage(id: a.substring(6))));
    } else if (a.startsWith('flow:') && app.flows.flows.any((f) => f.id == a.substring(5))) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => FlowEditor(id: a.substring(5))));
    } else if (a.startsWith('watch:') || a.startsWith('flow:') || a == 'watch' || a == 'flows' || a == 'tasks') {
      final a2 = a.startsWith('watch:') ? 'watch' : (a.startsWith('flow:') ? 'flows' : a);
      // Watchlist gehört jetzt zu den Prozessen
      final s = a2 == 'watch' ? AppSection.flows : AppSection.values.firstWhere((x) => x.name == a2);
      final desktop = MediaQuery.sizeOf(context).width >= 1100 && !_focus;
      if (desktop) {
        _go(s);
      } else {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => pageFor(s)));
      }
    } else if (a == 'newchat') {
      app.newConversation();
    } else if (a.startsWith('prompt:')) {
      final p = app.prompts.where((x) => x.id == a.substring(7)).firstOrNull;
      if (p != null) runSavedPrompt(context, app, p);
    }
  }

  AppSection _section = AppSection.chat;

  void _go(AppSection s) {
    if (_section != s) setState(() => _section = s);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!app.initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (app.initError == null) _onReady(app);
    if (app.initError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Start fehlgeschlagen:\n${app.initError}', textAlign: TextAlign.center),
          ),
        ),
      );
    }

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final desktop = w >= 1100;
      final tabletWide = w >= 900 && !desktop;
      final compact = !desktop && !tabletWide;
      final colors = AppColors.of(context);
      final divider = VerticalDivider(width: 1, color: colors.border);
      final section = desktop ? _section : AppSection.chat;
      final onChat = section == AppSection.chat;

      void toggleFocus() {
        final s = _scaffold.currentState;
        if (s?.isDrawerOpen ?? false) s!.closeDrawer();
        if (s?.isEndDrawerOpen ?? false) s!.closeEndDrawer();
        setState(() => _focus = !_focus);
      }

      final actions = <Widget>[
        if (!_focus) ...[
          // Glocke: Punkt in der Farbe der wichtigsten neuen Mitteilung (Warnung rot, Aktion violett, Erinnerung gelb …)
          Builder(builder: (context) {
            final top = app.notifier.topUnread ?? (app.todoCount > 0 ? NotifyKind.aktion : null);
            return PillIconButton(
              icon: top != null ? Icons.notifications_active : Icons.notifications_none,
              tooltip: top == null ? tr('Mitteilungen') : 'Mitteilungen – neu: ${top.label}',
              badge: top != null,
              badgeColor: top?.colors(context).$1,
              onPressed: () => openSection(context, AppSection.inbox),
            );
          }),
          const SizedBox(width: 6),
          if (!compact) ...[
            PillIconButton(
              icon: Icons.graphic_eq,
              tooltip: tr('Gesprächsmodus'),
              onPressed: app.status == EngineStatus.ready && !app.running ? () => openConversation(context) : null,
            ),
            const SizedBox(width: 6),
          ],
          if (!compact) ...[
            PillIconButton(icon: Icons.add, tooltip: tr('Neuer Chat'), onPressed: app.newConversation),
            const SizedBox(width: 6),
          ],
          if (compact)
            PillIconButton(
              icon: Icons.dashboard_outlined,
              tooltip: tr('Artefakte & Metriken'),
              badge: app.inspectorAttention,
              onPressed: () {
                app.clearInspectorAttention();
                _scaffold.currentState?.openEndDrawer();
              },
            )
          else
            PillIconButton(
              icon: Icons.view_sidebar_outlined,
              tooltip: _inspectorVisible ? tr('Artefakte ausblenden') : tr('Artefakte einblenden'),
              active: _inspectorVisible,
              badge: app.inspectorAttention && !_inspectorVisible,
              onPressed: () {
                app.clearInspectorAttention();
                setState(() => _inspectorChoice = !_inspectorVisible);
              },
            ),
          const SizedBox(width: 6),
        ],
        if (!compact || _focus)
          PillIconButton(
            icon: _focus ? Icons.close_fullscreen : Icons.open_in_full,
            tooltip: _focus ? tr('Fokus beenden') : tr('Fokus: nur der Chat'),
            active: _focus,
            onPressed: toggleFocus,
          ),
        const SizedBox(width: 12),
      ];

      final appBar = AppBar(
        toolbarHeight: 62,
        titleSpacing: desktop || _focus ? 20 : 4,
        title: _TitleBar(app: app),
        leading: desktop || _focus
            ? null
            : IconButton(
                tooltip: tr('Menü'),
                icon: ValueListenableBuilder(
                  valueListenable: app.updates.available,
                  builder: (context, info, _) => Badge(isLabelVisible: info != null, child: const Icon(Icons.menu)),
                ),
                onPressed: () => _scaffold.currentState?.openDrawer(),
              ),
        automaticallyImplyLeading: false,
        actions: actions,
      );

      final drawerWidth = compact ? (w * 0.88).clamp(280.0, 340.0) : 320.0;
      final chatArea = Row(children: [
        Expanded(
          child: Column(children: [
            ListenableBuilder(listenable: app.browser, builder: (context, _) => const GuideCard()),
            Expanded(child: BrowserDock(browser: app.browser, child: const ChatView())),
          ]),
        ),
        if (!compact && _inspectorVisible && !_focus) ...[
          divider,
          SizedBox(width: desktop ? 360 : 320, child: const InspectorPanel()),
        ],
      ]);

      ShellControls.openLeft = desktop || _focus ? null : () => _scaffold.currentState?.openDrawer();
      ShellControls.openRight = compact && !_focus
          ? () {
              app.clearInspectorAttention();
              _scaffold.currentState?.openEndDrawer();
            }
          : (_focus
              ? null
              : () {
                  app.clearInspectorAttention();
                  setState(() => _inspectorChoice = !_inspectorVisible);
                });
      return ShellNav(
        section: section,
        embedded: desktop && !_focus,
        go: _go,
        child: Scaffold(
          key: _scaffold,
          drawer: desktop || _focus
              ? null
              : Drawer(width: drawerWidth, child: const SafeArea(child: Sidebar(inDrawer: true))),
          endDrawer: compact && !_focus
              ? Drawer(
                  width: (w * 0.92).clamp(280.0, 420.0),
                  child: SafeArea(
                    child: Column(children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          tooltip: tr('Schließen'),
                          icon: const Icon(Icons.close),
                          onPressed: () => _scaffold.currentState?.closeEndDrawer(),
                        ),
                      ),
                      const Expanded(child: InspectorPanel()),
                    ]),
                  ),
                )
              : null,
          body: Row(
            children: [
              if (desktop && !_focus) ...[
                const SizedBox(width: 284, child: SafeArea(right: false, child: Sidebar())),
                divider,
              ],
              Expanded(
                child: onChat
                    ? Scaffold(appBar: appBar, body: SafeArea(top: false, child: chatArea))
                    : KeyedSubtree(key: ValueKey(section), child: pageFor(section)),
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final (color, label) = switch (app.status) {
      EngineStatus.ready => (c.mint, app.loadedModel?.displayName ?? tr('Modell bereit')),
      EngineStatus.loading => (c.amber, tr('Modell wird geladen …')),
      EngineStatus.error => (c.red, tr('Fehler beim Laden')),
      EngineStatus.none => (c.faint, tr('Kein Modell geladen')),
    };
    final route = app.routingLabel;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => openSystemCheck(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(app.current?.title ?? tr('Neuer Chat'),
              style: t.titleMedium?.copyWith(fontSize: 16.5), overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Row(children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Flexible(
              child: MonoText('$label · ${app.activeProfile.name}${route == null ? '' : ' · $route'}', size: 11),
            ),
          ]),
        ],
      ),
    );
  }
}
