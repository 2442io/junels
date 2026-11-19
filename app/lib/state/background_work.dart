// Plattform-Hintergrundfunktionen (Kanal "junels/background"):
// Android-Vordergrunddienst, Wecker für geplante Prompts, Benachrichtigungen.

import 'dart:io';

import 'package:flutter/services.dart';

class BackgroundWork {
  static const _channel = MethodChannel('junels/background');
  static const _files = MethodChannel('junels/files');
  static final Map<String, String> _active = {};

  /// Arbeit [key] beginnt; [text] erscheint in der Benachrichtigung.
  static Future<void> begin(String key, String text) async {
    if (!Platform.isAndroid) return;
    _active[key] = text;
    await _sync();
  }

  static Future<void> end(String key) async {
    if (!Platform.isAndroid) return;
    if (_active.remove(key) == null) return;
    await _sync();
  }

  static Future<void> _sync() async {
    try {
      if (_active.isEmpty) {
        await _channel.invokeMethod('stop');
      } else {
        await _channel.invokeMethod('start', {'text': _active.values.last});
      }
    } catch (_) {
      // ohne Dienst läuft die App trotzdem – nur eben nicht garantiert im Hintergrund
    }
  }

  /// Nimmt Aufrufe der Plattform entgegen (geplanter Prompt, Benachrichtigung angetippt).
  static void listen({
    required Future<void> Function(String id) onRunPrompt,
    required void Function(String conversationId) onOpenConversation,
  }) {
    _channel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
      switch (call.method) {
        case 'runPrompt':
          await onRunPrompt(args['id'] as String? ?? '');
        case 'openConversation':
          onOpenConversation(args['id'] as String? ?? '');
      }
      return null;
    });
  }

  /// Android: Wecker für die nächsten Termine setzen (laufen auch bei geschlossener App).
  static Future<void> schedule(List<({String id, String title, DateTime at})> items) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('schedule', {
        'items': [for (final i in items) {'id': i.id, 'title': i.title, 'at': i.at.millisecondsSinceEpoch}],
      });
    } catch (_) {}
  }

  static Future<void> notify(String title, String body, {String? conversationId}) async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('notify', {
          'title': title,
          'body': body,
          'conversation': conversationId,
          'id': (conversationId ?? title).hashCode & 0x7FFFFFFF,
        });
      } else if (Platform.isMacOS) {
        await _files.invokeMethod('notify', {'title': title, 'body': body});
      }
    } catch (_) {}
  }

  static Future<void> requestNotifyPermission() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestNotifyPermission');
    } catch (_) {}
  }

  static Future<String?> takeLaunchConversation() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('takeLaunchConversation');
    } catch (_) {
      return null;
    }
  }

  /// Hintergrund-Engine (Android): welcher Prompt soll laufen, und Bescheid geben, wenn fertig.
  static Future<String?> headlessTask() => _channel.invokeMethod<String>('getTask');
  static Future<void> headlessFinished() => _channel.invokeMethod('finished');
}
