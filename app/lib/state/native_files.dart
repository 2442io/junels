// Dateifunktionen der Plattform (eigener Kanal "junels/files"):
// PDF-Text lesen, Dateien öffnen, teilen, im Finder zeigen, speichern unter.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

class NativeFiles {
  static const _ch = MethodChannel('junels/files');

  static String mimeFor(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => 'application/pdf',
      'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'md' => 'text/markdown',
      'txt' => 'text/plain',
      'csv' => 'text/csv',
      _ => '*/*',
    };
  }

  /// Text aus einem PDF (Seiten getrennt durch Leerzeilen).
  static Future<({String text, int pages})> pdfText(String path, {int maxPages = 300}) async {
    final r = await _ch.invokeMapMethod<String, Object?>('pdfText', {'path': path, 'maxPages': maxPages});
    return (text: (r?['text'] as String?) ?? '', pages: (r?['pages'] as num?)?.toInt() ?? 0);
  }

  static Future<void> open(String path) => _ch.invokeMethod('open', {'path': path, 'mime': mimeFor(path)});

  /// Webseite im Standardbrowser öffnen.
  /// Android: heruntergeladenes Update installieren (System-Dialog).
  static Future<void> installApk(String path) => _ch.invokeMethod('installApk', {'path': path});

  static Future<void> openUrl(String url) => _ch.invokeMethod('openUrl', {'url': url});

  static Future<void> share(String path) => _ch.invokeMethod('share', {'path': path, 'mime': mimeFor(path)});

  /// Nur macOS: Datei im Finder markieren.
  static Future<void> reveal(String path) => _ch.invokeMethod('reveal', {'path': path});

  /// "Speichern unter …": liefert den Zielpfad oder null.
  static Future<String?> saveAs(String path) async {
    final name = path.split(Platform.pathSeparator).last;
    final bytes = await File(path).readAsBytes();
    final ext = name.contains('.') ? name.split('.').last : null;
    final target = await FilePicker.platform.saveFile(
      dialogTitle: 'Speichern unter',
      fileName: name,
      type: ext == null ? FileType.any : FileType.custom,
      allowedExtensions: ext == null ? null : [ext],
      bytes: bytes,
    );
    if (target == null) return null;
    // Desktop: Datei selbst schreiben, falls das Plugin nur den Pfad liefert
    if (Platform.isMacOS) {
      final f = File(target);
      if (!f.existsSync() || f.lengthSync() != bytes.length) await f.writeAsBytes(bytes);
    }
    return target;
  }
}
