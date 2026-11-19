// Hintergrundbetrieb auf Android: solange der Agent antwortet oder ein Download läuft,
// hält ein Vordergrunddienst (mit Benachrichtigung) die App am Leben.

import 'dart:io';

import 'package:flutter/services.dart';

class BackgroundWork {
  static const _channel = MethodChannel('junels/background');
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
}
