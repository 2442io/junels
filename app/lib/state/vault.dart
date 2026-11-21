// Tresor für Geheimnisse (Passwörter, Anmelde-Tokens).
// Android: verschlüsselt mit einem Schlüssel aus dem Android-Keystore. Mac: Schlüsselbund.
// Der Agent hat keinen Zugriff: Es gibt kein Werkzeug, das den Tresor liest – nur App-Code
// (Mailversand, MCP-Anmeldung) holt sich gezielt, was er braucht.

import 'dart:io';

import 'package:flutter/services.dart';

class Vault {
  static const _ch = MethodChannel('junels/device');
  static final Map<String, String> _memory = {}; // Fallback auf anderen Plattformen (nur bis zum Beenden)

  static bool get secure => Platform.isAndroid || Platform.isMacOS;

  static Future<String?> read(String key) async {
    if (!secure) return _memory[key];
    try {
      return await _ch.invokeMethod<String>('vaultGet', {'key': key});
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, String? value) async {
    if (!secure) {
      value == null ? _memory.remove(key) : _memory[key] = value;
      return;
    }
    await _ch.invokeMethod('vaultSet', {'key': key, 'value': value});
  }

  static Future<void> delete(String key) => write(key, null);

  /// Nur Namen der Einträge (für die Anzeige „Was liegt im Tresor?“), nie die Werte.
  static Future<List<String>> keys() async {
    if (!secure) return _memory.keys.toList();
    try {
      return ((await _ch.invokeMethod<List>('vaultKeys')) ?? const []).cast<String>();
    } catch (_) {
      return const [];
    }
  }
}
