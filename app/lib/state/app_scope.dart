import 'package:flutter/widgets.dart';

import 'app_controller.dart';

/// Stellt den [AppController] im Widget-Baum bereit und baut bei Änderungen neu.
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({super.key, required AppController controller, required super.child})
      : super(notifier: controller);

  static AppController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Zugriff ohne Abhängigkeit (für Callbacks).
  static AppController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
