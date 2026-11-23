import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'state/app_scope.dart';
import 'state/background_work.dart';
import 'state/voice_service.dart' show appLog;
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final prev = FlutterError.onError;
  FlutterError.onError = (d) {
    appLog('App', '${d.exceptionAsString()}${d.stack == null ? '' : ' @ ${d.stack.toString().split('\n').take(3).join(' | ')}'}',
        error: true);
    prev?.call(d);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    appLog('App', '$e @ ${st.toString().split('\n').take(3).join(' | ')}', error: true);
    return false;
  };
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
    if (id != null && !await app.runAutomation(id)) {
      final p = app.prompts.where((x) => x.id == id).firstOrNull;
      if (p != null) await app.runPrompt(p, automated: true);
    }
    await app.unloadModel();
  } catch (e) {
    await BackgroundWork.notify('Geplanter Prompt fehlgeschlagen', 'Fehler: $e', kind: 'warnung');
  } finally {
    await BackgroundWork.headlessFinished();
  }
}

class OfflineAgentApp extends StatelessWidget {
  const OfflineAgentApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      child: ValueListenableBuilder<bool?>(
        valueListenable: controller.darkMode,
        builder: (context, dark, _) {
          return MaterialApp(
            title: 'Junels',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            themeMode: dark == null ? ThemeMode.system : (dark ? ThemeMode.dark : ThemeMode.light),
            home: const HomeShell(),
          );
        },
      ),
    );
  }
}
