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
import 'internet_menu.dart';
import 'conversation_page.dart';
import 'sidebar.dart';
import 'system_check.dart';
import 'nav.dart';
import 'theme.dart';

/// Fragt, ob der Agent ins Internet darf.
Future<NetworkChoice> askNetworkConsent(BuildContext context, String purpose) async {
  final r = await showDialog<NetworkChoice>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.public),
      title: const Text('Internetzugriff erlauben?'),
      content: Text('Der Agent möchte ins Internet:\n\n$purpose\n\n'
          'Dabei wird nur diese Anfrage gesendet. Das Sprachmodell selbst läuft weiter lokal.\n\n'
          '„Einmal“ gilt für diese Frage, „Ganzer Chat“ für alle weiteren Fragen in diesem Chat.'),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        Row(children: [
          Expanded(
            child: TextButton(onPressed: () => Navigator.pop(ctx, NetworkChoice.deny), child: const Text('Nein')),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, NetworkChoice.once),
                child: const Text('Einmal', textAlign: TextAlign.center)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: FilledButton(
                onPressed: () => Navigator.pop(ctx, NetworkChoice.chat),
                child: const Text('Ganzer Chat', textAlign: TextAlign.center)),
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
      title: const Text('Cloud-Anbieter verwenden?'),
      content: Text('$reason\n\n'
          'Dabei gehen deine Frage, der bisherige Chatverlauf und gefundene Inhalte an den Anbieter.\n\n'
          '„Einmal“ gilt für diese Frage, „Ganzer Chat“ für alle weiteren Fragen in diesem Chat.'),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        Row(children: [
          Expanded(child: TextButton(onPressed: () => Navigator.pop(ctx, NetworkChoice.deny), child: const Text('Nein'))),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, NetworkChoice.once),
                child: const Text('Einmal', textAlign: TextAlign.center)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: FilledButton(
                onPressed: () => Navigator.pop(ctx, NetworkChoice.chat),
                child: const Text('Ganzer Chat', textAlign: TextAlign.center)),
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
  bool _inspectorVisible = true;
  bool _focus = false; // Fokus-Modus: nur der Chat
  bool _firstRunHandled = false;

  void _onReady(AppController app) {
    if (_firstRunHandled) return;
    _firstRunHandled = true;
    app.consentHandler = (purpose) => askNetworkConsent(context, purpose);
    app.cloudConsentHandler = (reason) => askCloudConsent(context, reason);
    app.deviceBridge.confirmHandler = (title, detail) => _confirm(title, detail);
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nein')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ja, ausführen')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Schnellstart vom Startbildschirm / Dock-Menü.
  void _launch(AppController app) {
    final a = app.pendingLaunch.value;
    if (a == null || !mounted) return;
    app.pendingLaunch.value = null;
    if (a == 'conversation') {
      openConversation(context);
    } else if (a == 'watch' || a == 'flows' || a == 'tasks') {
      // Watchlist gehört jetzt zu den Prozessen
      final s = a == 'watch' ? AppSection.flows : AppSection.values.firstWhere((x) => x.name == a);
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
          AiModeMenu(compact: compact),
          const SizedBox(width: 6),
          InternetMenu(compact: compact),
          const SizedBox(width: 6),
          PillIconButton(
            icon: app.todoCount > 0 ? Icons.notifications_active : Icons.notifications_none,
            tooltip: 'Mitteilungen',
            badge: app.todoCount > 0 || app.notifier.hasWarning,
            badgeColor: app.todoCount > 0 ? colors.violet : colors.red,
            onPressed: () => openSection(context, AppSection.inbox),
          ),
          const SizedBox(width: 6),
          PillIconButton(
            icon: Icons.graphic_eq,
            tooltip: 'Gesprächsmodus',
            onPressed: app.status == EngineStatus.ready && !app.running ? () => openConversation(context) : null,
          ),
          const SizedBox(width: 6),
          if (!compact) ...[
            PillIconButton(icon: Icons.add, tooltip: 'Neuer Chat', onPressed: app.newConversation),
            const SizedBox(width: 6),
          ],
          if (compact)
            PillIconButton(
              icon: Icons.dashboard_outlined,
              tooltip: 'Artefakte & Metriken',
              badge: app.inspectorAttention,
              onPressed: () {
                app.clearInspectorAttention();
                _scaffold.currentState?.openEndDrawer();
              },
            )
          else
            PillIconButton(
              icon: Icons.view_sidebar_outlined,
              tooltip: _inspectorVisible ? 'Artefakte ausblenden' : 'Artefakte einblenden',
              active: _inspectorVisible,
              badge: app.inspectorAttention && !_inspectorVisible,
              onPressed: () {
                app.clearInspectorAttention();
                setState(() => _inspectorVisible = !_inspectorVisible);
              },
            ),
          const SizedBox(width: 6),
        ],
        if (!compact || _focus)
          PillIconButton(
            icon: _focus ? Icons.close_fullscreen : Icons.open_in_full,
            tooltip: _focus ? 'Fokus beenden' : 'Fokus: nur der Chat',
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
                tooltip: 'Menü',
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
              ? Drawer(width: (w * 0.92).clamp(280.0, 420.0), child: const SafeArea(child: InspectorPanel()))
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
      EngineStatus.ready => (c.mint, app.loadedModel?.displayName ?? 'Modell bereit'),
      EngineStatus.loading => (c.amber, 'Modell wird geladen …'),
      EngineStatus.error => (c.red, 'Fehler beim Laden'),
      EngineStatus.none => (c.faint, 'Kein Modell geladen'),
    };
    final route = app.routingLabel;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => openSystemCheck(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(app.current?.title ?? 'Neuer Chat',
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
