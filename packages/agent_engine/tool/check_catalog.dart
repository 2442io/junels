// Prüft alle Download-Adressen des Katalogs (und ob es zu Vision-Modellen eine mmproj-Datei gibt).
import 'dart:convert';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';

Future<void> main() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  var bad = 0;
  for (final e in modelCatalog) {
    var status = 0;
    var size = -1;
    try {
      var uri = Uri.parse(e.url);
      for (var i = 0; i < 5; i++) {
        final req = await client.headUrl(uri);
        req.followRedirects = false;
        final res = await req.close();
        await res.drain<void>();
        status = res.statusCode;
        size = int.tryParse(res.headers.value('x-linked-size') ?? '') ?? res.contentLength;
        final loc = res.headers.value('location');
        if (status >= 300 && status < 400 && loc != null) {
          uri = uri.resolve(loc);
          continue;
        }
        break;
      }
    } catch (err) {
      status = -1;
    }
    final ok = status == 200;
    if (!ok) bad++;
    final sizeInfo = size > 0 ? '${(size / (1 << 20)).round()} MB (Katalog ${(e.sizeBytes / (1 << 20)).round()} MB)' : '';
    print('${ok ? 'ok  ' : 'FAIL'} ${e.id.padRight(18)} $status $sizeInfo');
    if (e.vision && e.hfRepo != null) {
      try {
        final req = await client.getUrl(Uri.parse('https://huggingface.co/api/models/${e.hfRepo}/tree/main'));
        final res = await req.close();
        final list = jsonDecode(await res.transform(utf8.decoder).join()) as List;
        final mm = list.cast<Map>().map((f) => f['path'] as String).where((p) => p.toLowerCase().startsWith('mmproj')).toList();
        print('     mmproj: ${mm.isEmpty ? 'KEINE' : mm.join(', ')}');
        if (mm.isEmpty) bad++;
      } catch (err) {
        print('     mmproj: Fehler $err');
        bad++;
      }
    }
  }
  client.close();
  print(bad == 0 ? '\nAlle Adressen erreichbar.' : '\n$bad Problem(e).');
  exit(bad == 0 ? 0 : 1);
}
