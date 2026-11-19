import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'state/app_scope.dart';
import 'state/background_work.dart';
import 'ui/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  controller.init();
  runApp(OfflineAgentApp(controller: controller));
}

/// Einstieg der Android-Hintergrund-Engine: führt einen geplanten Prompt ohne Oberfläche aus.
@pragma('vm:entry-point')
Future<void> backgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final id = await BackgroundWork.headlessTask();
    final app = AppController()..headless = true;
    await app.init();
    final p = app.prompts.where((x) => x.id == id).firstOrNull;
    if (p != null) await app.runPrompt(p, automated: true);
    await app.unloadModel();
  } catch (e) {
    await BackgroundWork.notify('Geplanter Prompt', 'Fehler: $e');
  } finally {
    await BackgroundWork.headlessFinished();
  }
}

class OfflineAgentApp extends StatelessWidget {
  const OfflineAgentApp({super.key, required this.controller});
  final AppController controller;

  static ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2E6F6A), brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: EdgeInsets.zero,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      child: ValueListenableBuilder<bool?>(
        valueListenable: controller.darkMode,
        builder: (context, dark, _) {
          return MaterialApp(
            title: 'Offline Agent',
            debugShowCheckedModeBanner: false,
            theme: _theme(Brightness.light),
            darkTheme: _theme(Brightness.dark),
            themeMode: dark == null ? ThemeMode.system : (dark ? ThemeMode.dark : ThemeMode.light),
            home: const HomeShell(),
          );
        },
      ),
    );
  }
}
