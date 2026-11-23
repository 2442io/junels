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

  /// Benachrichtigung sofort oder zum Zeitpunkt [at] (bleibt auch bei geschlossener App).
  /// [kind]: aktion | warnung | erinnerung | ergebnis | info | ruhig – bestimmt Kanal, Farbe, Symbol, Ton.
  /// [id]: gleiche id ersetzt eine vorhandene Meldung (Bündeln).
  static Future<void> notify(String title, String body,
      {String? conversationId, DateTime? at, String kind = 'info', String? id}) async {
    try {
      final args = {
        'title': title,
        'body': body,
        'conversation': conversationId,
        'kind': kind,
        'id': stableId(id ?? '${conversationId ?? title}${at?.millisecondsSinceEpoch ?? ''}'),
        if (at != null) 'at': at.millisecondsSinceEpoch,
      };
      if (Platform.isAndroid) {
        await _channel.invokeMethod('notify', args);
      } else if (Platform.isMacOS) {
        await _files.invokeMethod('notify', args);
      }
    } catch (_) {}
  }

  /// Gleiche Zeichenkette → gleiche Nummer, auch nach Neustart (String.hashCode ist das nicht).
  static int stableId(String s) {
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h & 0x7FFFFFFF;
  }

  /// Geplante oder angezeigte Meldung entfernen.
  static Future<void> cancelNotify(String id) async {
    try {
      final args = {'id': stableId(id)};
      if (Platform.isAndroid) {
        await _channel.invokeMethod('cancelNotify', args);
      } else if (Platform.isMacOS) {
        await _files.invokeMethod('cancelNotify', args);
      }
    } catch (_) {}
  }

  /// „Schlummern“/„Erledigt“, die in Meldungen getippt wurden (seit dem letzten Abruf).
  static Future<List<({int id, String action, DateTime at})>> takeNotifyEvents() async {
    try {
      final r = Platform.isAndroid
          ? await _channel.invokeMethod<List>('takeNotifyEvents')
          : Platform.isMacOS
              ? await _files.invokeMethod<List>('takeNotifyEvents')
              : null;
      return [
        for (final m in (r ?? const []).cast<Map>())
          (
            id: (m['id'] as num).toInt(),
            action: '${m['action']}',
            at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num?)?.toInt() ?? 0),
          ),
      ];
    } catch (_) {
      return const [];
    }
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
