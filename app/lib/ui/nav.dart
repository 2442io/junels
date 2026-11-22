// Navigation zwischen den Hauptbereichen. Auf großen Bildschirmen bleibt die
// Seitenleiste stehen und der Bereich erscheint rechts daneben, auf dem Handy
// öffnet er sich als eigene Seite.

import 'package:flutter/material.dart';

import 'help_page.dart';
import 'knowledge_page.dart';
import 'settings_page.dart';
import 'tasks_page.dart';
import 'watchlist_page.dart';
import 'flows_page.dart';

enum AppSection {
  chat('Chat', Icons.forum_outlined),
  tasks('Geplante Aufgaben', Icons.schedule),
  flows('Prozesse & Watchlist', Icons.account_tree_outlined),
  watch('Watchlist', Icons.radar),
  prompts('Prompt-Vorlagen', Icons.bolt_outlined),
  knowledge('Wissen & Gedächtnis', Icons.local_library_outlined),
  activity('Aktivitäten', Icons.history),
  settings('Einstellungen', Icons.settings_outlined),
  help('Hilfe', Icons.help_outline);

  const AppSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

Widget pageFor(AppSection s) => switch (s) {
      AppSection.tasks => const TasksPage(),
      AppSection.flows => const FlowsPage(),
      AppSection.watch => const WatchlistPage(),
      AppSection.prompts => const PromptsPage(),
      AppSection.knowledge => const KnowledgePage(),
      AppSection.activity => const ActivityPage(),
      AppSection.settings => const SettingsPage(),
      AppSection.help => const HelpPage(),
      AppSection.chat => const SizedBox(),
    };

/// Stellt den aktiven Bereich bereit (nur auf großen Bildschirmen eingebettet).
class ShellNav extends InheritedWidget {
  const ShellNav({super.key, required this.section, required this.go, required this.embedded, required super.child});
  final AppSection section;
  final ValueChanged<AppSection> go;
  final bool embedded;

  static ShellNav? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellNav>();

  @override
  bool updateShouldNotify(ShellNav old) => old.section != section || old.embedded != embedded;
}

/// Wechselt in einen Bereich: eingebettet (Desktop) oder als neue Seite (Handy).
void openSection(BuildContext context, AppSection s, {bool fromDrawer = false}) {
  final nav = context.getInheritedWidgetOfExactType<ShellNav>();
  if (nav != null && nav.embedded) {
    nav.go(s);
    return;
  }
  final navigator = Navigator.of(context);
  if (fromDrawer) navigator.maybePop();
  nav?.go(AppSection.chat);
  if (s == AppSection.chat) return;
  navigator.push(MaterialPageRoute(builder: (_) => pageFor(s)));
}
