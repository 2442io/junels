// Three-Pane-Layout mit drei Breakpoints (SRS Abschnitt 3):
//   < 900 px   Smartphone / Tablet hochkant: Sidebar und Inspector als Drawer
//   900–1200   Tablet quer: Sidebar als Drawer, Inspector fest rechts
//   ≥ 1200     Mac / großes Tablet: alle drei Bereiche sichtbar

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import 'chat_view.dart';
import 'inspector.dart';
import 'internet_menu.dart';
import 'conversation_page.dart';
import 'sidebar.dart';
import 'system_check.dart';

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
    if (app.needsSystemCheck) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openSystemCheck(context);
      });
    }
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
      final desktop = w >= 1200;
      final tabletWide = w >= 900 && !desktop;
      final compact = !desktop && !tabletWide;
      final scheme = Theme.of(context).colorScheme;
      final divider = VerticalDivider(width: 1, color: scheme.outlineVariant);

      final focusButton = IconButton(
        tooltip: _focus ? 'Fokus beenden' : 'Fokus: nur der Chat',
        icon: Icon(_focus ? Icons.fullscreen_exit : Icons.center_focus_strong_outlined),
        onPressed: () {
          final s = _scaffold.currentState;
          if (s?.isDrawerOpen ?? false) s!.closeDrawer();
          if (s?.isEndDrawerOpen ?? false) s!.closeEndDrawer();
          setState(() => _focus = !_focus);
        },
      );
      final appBar = AppBar(
        titleSpacing: desktop || _focus ? 16 : 0,
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
        actions: _focus
            ? [focusButton, const SizedBox(width: 4)]
            : [
          focusButton,
          const InternetMenu(),
          IconButton(
            tooltip: 'Gesprächsmodus',
            icon: const Icon(Icons.record_voice_over_outlined),
            onPressed: app.status == EngineStatus.ready && !app.running ? () => openConversation(context) : null,
          ),
          IconButton(
            tooltip: 'Systemcheck & Modelle',
            icon: const Icon(Icons.speed_outlined),
            onPressed: () => openSystemCheck(context),
          ),
          IconButton(
            tooltip: 'Neuer Chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: app.running ? null : app.newConversation,
          ),
          if (compact)
            IconButton(
              tooltip: 'Artefakte & Metriken',
              icon: Badge(
                isLabelVisible: app.inspectorAttention,
                child: const Icon(Icons.dashboard_outlined),
              ),
              onPressed: () {
                app.clearInspectorAttention();
                _scaffold.currentState?.openEndDrawer();
              },
            )
          else
            IconButton(
              tooltip: _inspectorVisible ? 'Inspector ausblenden' : 'Inspector einblenden',
              icon: Badge(
                isLabelVisible: app.inspectorAttention && !_inspectorVisible,
                child: Icon(_inspectorVisible ? Icons.view_sidebar : Icons.view_sidebar_outlined),
              ),
              onPressed: () {
                app.clearInspectorAttention();
                setState(() => _inspectorVisible = !_inspectorVisible);
              },
            ),
          const SizedBox(width: 4),
        ],
      );

      final drawerWidth = compact ? (w * 0.88).clamp(280.0, 360.0) : 340.0;

      return Scaffold(
        key: _scaffold,
        appBar: appBar,
        drawer: desktop || _focus
            ? null
            : Drawer(width: drawerWidth, child: const SafeArea(child: Sidebar(inDrawer: true))),
        endDrawer: compact && !_focus
            ? Drawer(width: (w * 0.92).clamp(280.0, 420.0), child: const SafeArea(child: InspectorPanel()))
            : null,
        body: SafeArea(
          top: false,
          child: Row(
            children: [
              if (desktop && !_focus) ...[
                const SizedBox(width: 300, child: Sidebar()),
                divider,
              ],
              const Expanded(child: ChatView()),
              if (!compact && _inspectorVisible && !_focus) ...[
                divider,
                SizedBox(width: desktop ? 360 : 320, child: const InspectorPanel()),
              ],
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
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = switch (app.status) {
      EngineStatus.ready => (Colors.green, app.loadedModel?.displayName ?? 'Modell bereit'),
      EngineStatus.loading => (Colors.orange, 'Modell wird geladen …'),
      EngineStatus.error => (scheme.error, 'Fehler beim Laden'),
      EngineStatus.none => (scheme.outline, 'Kein Modell geladen'),
    };
    return Row(
      children: [
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(app.current?.title ?? 'Offline Agent',
                  style: t.titleMedium, overflow: TextOverflow.ellipsis),
              Row(
                children: [
                  Container(
                      width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('$label · ${app.activeProfile.name}',
                        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'KI läuft lokal – Internet nur nach Freigabe',
          child: Icon(Icons.cloud_off_outlined, size: 18, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
