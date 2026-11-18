// Download mit Fortsetzen nach Abbruch (HTTP Range), Weiterleitungen und Abbrechen.
// Nur dart:io, keine Pakete.

import 'dart:async';
import 'dart:io';

class DownloadProgress {
  DownloadProgress(this.received, this.total, this.bytesPerSecond);
  final int received;
  final int total; // -1 = unbekannt
  final double bytesPerSecond;

  double? get fraction => total > 0 ? received / total : null;

  Duration? get eta => total > 0 && bytesPerSecond > 0
      ? Duration(seconds: ((total - received) / bytesPerSecond).round())
      : null;
}

class DownloadCancelled implements Exception {
  @override
  String toString() => 'Download abgebrochen';
}

class DownloadException implements Exception {
  DownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CancelToken {
  bool _cancelled = false;
  HttpClient? _client;
  bool get isCancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }
}

class Downloader {
  Downloader({this.userAgent = 'OfflineAgent/1.1'});
  final String userAgent;

  /// Lädt [url] nach [targetPath]. Unvollständige Daten liegen in
  /// "<target>.part" und werden beim nächsten Versuch fortgesetzt.
  Future<File> download(
    String url,
    String targetPath, {
    void Function(DownloadProgress)? onProgress,
    CancelToken? cancel,
    int maxRedirects = 10,
  }) async {
    final part = File('$targetPath.part');
    await part.parent.create(recursive: true);
    var offset = await part.exists() ? await part.length() : 0;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = userAgent;
    cancel?._client = client;

    try {
      var uri = Uri.parse(url);
      HttpClientResponse? resp;
      for (var hop = 0; hop <= maxRedirects; hop++) {
        if (cancel?.isCancelled ?? false) throw DownloadCancelled();
        final req = await client.getUrl(uri);
        req.followRedirects = false; // selbst folgen, damit der Range-Header erhalten bleibt
        if (offset > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
        final r = await req.close();
        if (r.isRedirect || (r.statusCode >= 300 && r.statusCode < 400)) {
          final loc = r.headers.value(HttpHeaders.locationHeader);
          await r.drain<void>();
          if (loc == null) throw DownloadException('Weiterleitung ohne Ziel (${r.statusCode})');
          uri = uri.resolve(loc);
          continue;
        }
        resp = r;
        break;
      }
      if (resp == null) throw DownloadException('Zu viele Weiterleitungen');

      int total;
      if (resp.statusCode == 206) {
        final range = resp.headers.value(HttpHeaders.contentRangeHeader); // bytes a-b/total
        final m = RegExp(r'/(\d+)$').firstMatch(range ?? '');
        total = m != null ? int.parse(m.group(1)!) : offset + resp.contentLength;
      } else if (resp.statusCode == 200) {
        offset = 0; // Server unterstützt kein Range: von vorne
        total = resp.contentLength;
      } else if (resp.statusCode == 416 && offset > 0) {
        // Bereich ungültig: .part ist vermutlich vollständig
        await resp.drain<void>();
        total = offset;
      } else {
        await resp.drain<void>();
        throw DownloadException(switch (resp.statusCode) {
          401 || 403 => 'Zugriff verweigert (HTTP ${resp.statusCode}). Das Modell braucht evtl. eine Anmeldung.',
          404 => 'Datei nicht gefunden (HTTP 404). Die Adresse hat sich vermutlich geändert.',
          _ => 'Download fehlgeschlagen (HTTP ${resp.statusCode})',
        });
      }

      if (resp.statusCode != 416) {
        final sink = part.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
        var received = offset;
        var windowBytes = 0;
        var windowStart = DateTime.now();
        var speed = 0.0;
        var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
        try {
          await for (final chunk in resp) {
            if (cancel?.isCancelled ?? false) throw DownloadCancelled();
            sink.add(chunk);
            received += chunk.length;
            windowBytes += chunk.length;
            final now = DateTime.now();
            final dt = now.difference(windowStart).inMilliseconds;
            if (dt >= 1000) {
              final current = windowBytes * 1000 / dt;
              speed = speed == 0 ? current : speed * 0.7 + current * 0.3;
              windowBytes = 0;
              windowStart = now;
            }
            if (now.difference(lastReport).inMilliseconds >= 200) {
              lastReport = now;
              onProgress?.call(DownloadProgress(received, total, speed));
            }
          }
        } on HttpException catch (e) {
          if (cancel?.isCancelled ?? false) throw DownloadCancelled();
          throw DownloadException('Verbindung unterbrochen: ${e.message}. Erneut tippen setzt den Download fort.');
        } finally {
          await sink.flush();
          await sink.close();
        }
        onProgress?.call(DownloadProgress(received, total, speed));
        if (total > 0 && received < total) {
          throw DownloadException('Unvollständig (${received ~/ (1 << 20)} von ${total ~/ (1 << 20)} MB). '
              'Erneut tippen setzt den Download fort.');
        }
      }

      final target = File(targetPath);
      if (await target.exists()) await target.delete();
      return await part.rename(targetPath);
    } on SocketException catch (e) {
      if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      throw DownloadException('Keine Verbindung: ${e.message}');
    } on HandshakeException catch (e) {
      throw DownloadException('Sichere Verbindung fehlgeschlagen: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }
}
