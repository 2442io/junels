// Schnelle Wege: aus jeder Unterseite direkt in einen anderen Bereich oder zurück zum Chat –
// ohne Seite für Seite zurückzugehen.

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import 'nav.dart';
import 'self_test_page.dart';
import 'monitor_page.dart';
import 'theme.dart';

/// AppBar mit Schnellnavigation (⋯-Raster rechts), sobald man tiefer als die Startseite ist.
class JAppBar extends AppBar {
  JAppBar({
    super.key,
    super.title,
    List<Widget>? actions,
    super.leading,
    super.bottom,
    super.backgroundColor,
    super.foregroundColor,
    super.toolbarHeight,
    super.titleSpacing,
    super.automaticallyImplyLeading,
    super.centerTitle,
  }) : super(actions: [...?actions, const QuickNavButton(), const SizedBox(width: 4)]);
}

class QuickNavButton extends StatelessWidget {
  const QuickNavButton({super.key});

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route is PopupRoute) return const SizedBox.shrink();
    // überall gleich: auf jeder Seite, auch am Desktop und auf der Startseite
    return IconButton(
      tooltip: 'Schnell wechseln',
      icon: const Icon(Icons.apps_rounded),
      onPressed: () => showQuickNav(context),
    );
  }
}

/// Zurück zum Chat – alle offenen Seiten auf einmal schließen.
void goHome(BuildContext context) => Navigator.of(context).popUntil((r) => r.isFirst);

Future<void> showQuickNav(BuildContext context) async {
  final app = AppScope.read(context);
  final rootContext = Navigator.of(context, rootNavigator: true).context;
  // Desktop: Bereiche sind eingebettet (Seitenleiste) – dorthin wechseln statt eine Seite zu öffnen
  final shell = context.getInheritedWidgetOfExactType<ShellNav>();
  final c = AppColors.of(context);
  final sections = [
    (AppSection.inbox, app.todoCount > 0 ? '${app.todoCount}' : null),
    (AppSection.skills, null),
    (AppSection.tasks, null),
    (AppSection.prompts, null),
    (AppSection.knowledge, app.memory.pending.isNotEmpty ? '${app.memory.pending.length}' : null),
    (AppSection.activity, null),
    (AppSection.settings, null),
    (AppSection.help, null),
  ];
  final picked = await showSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Center(
        heightFactor: 1,
        // Mac/Tablet: nicht über die ganze Breite ziehen – sonst werden die Kacheln riesig und unten abgeschnitten
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.forum_outlined),
                label: const Text('Zum Chat'),
                onPressed: () => Navigator.pop(ctx, 'home'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Neuer Chat'),
                onPressed: () => Navigator.pop(ctx, 'new'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          const SizedBox(height: 12),
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 120,
              mainAxisExtent: 92,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            children: [
              for (final (s, badge) in sections)
                InkWell(
                  borderRadius: BorderRadius.circular(Ui.r),
                  onTap: () => Navigator.pop(ctx, s),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Badge(
                      isLabelVisible: badge != null,
                      label: Text(badge ?? ''),
                      backgroundColor: c.violet,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: c.raised, borderRadius: BorderRadius.circular(12)),
                        child: Icon(s.icon, size: 22),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(_short(s), textAlign: TextAlign.center, maxLines: 2, style: Theme.of(ctx).textTheme.labelSmall),
                  ]),
                ),
            ],
          ),
        ]),
          ),
        ),
      ),
    ),
  );
  if (picked == null || !rootContext.mounted) return;
  final navigator = Navigator.of(rootContext);
  navigator.popUntil((r) => r.isFirst);
  if (picked == 'monitor') {
    if (rootContext.mounted) Navigator.of(rootContext).push(MaterialPageRoute(builder: (_) => const MonitorPage()));
    return;
  }
  if (picked == 'selftest') {
    if (rootContext.mounted) Navigator.of(rootContext).push(MaterialPageRoute(builder: (_) => const SelfTestPage()));
    return;
  }
  if (picked == 'home' || picked == 'new') {
    if (picked == 'new') app.newConversation();
    shell?.go(AppSection.chat);
    return;
  }
  if (picked is! AppSection) return;
  if (shell != null && shell.embedded) {
    shell.go(picked);
  } else {
    shell?.go(AppSection.chat);
    navigator.push(MaterialPageRoute(builder: (_) => pageFor(picked)));
  }
}

String _short(AppSection s) => switch (s) {
      AppSection.inbox => 'Benach­richtigungen',
      AppSection.flows => 'Prozesse',
      AppSection.tasks => 'Geplant',
      AppSection.prompts => 'Vorlagen',
      AppSection.skills => 'Skills & Abläufe',
      AppSection.knowledge => 'Wissen',
      AppSection.activity => 'Aktivität',
      AppSection.settings => 'Einstellungen',
      AppSection.help => 'Hilfe',
      _ => s.label,
    };
