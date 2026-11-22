// Ermittelt das Design für eine Präsentation bzw. ein Dokument:
// PowerPoint-Vorlage > Office-Design (Word/Excel) > Farben aus Beispielbildern > Design passend zum Thema.

import 'dart:io';
import 'dart:typed_data';

import '../documents/design.dart';
import '../documents/design_library.dart';
import '../documents/office_read.dart';
import 'network_tools.dart' show browserUserAgent;
import 'tool.dart';

/// Bild → (Breite, Höhe, RGBA) – in der App über dart:ui (JPEG, PNG, WebP …).
typedef ImageDecoder = Future<(int, int, Uint8List)?> Function(Uint8List bytes);

class ResolvedDesign {
  ResolvedDesign(this.design, this.template, this.notes, {this.templateBytes});
  final SlideDesign design;
  final PptxTemplate? template;

  /// Originaldatei der PowerPoint-Vorlage (für spätere Änderungen gespeichert)
  final Uint8List? templateBytes;
  final List<String> notes;

  /// Kurzbeschreibung für die Rückmeldung.
  String get summary => [
        template != null ? 'Design: deine PowerPoint-Vorlage' : 'Design: ${design.name}',
        if (design.source != null && template == null) '(${design.source})',
        ...notes,
      ].join(' ');
}

/// Lädt Bytes aus dem Netz (max. 15 MB).
Future<(Uint8List, String)> httpGetBytes(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = browserUserAgent;
  try {
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'image/avif,image/webp,image/png,image/jpeg,text/html;q=0.8,*/*;q=0.5');
    final resp = await req.close().timeout(const Duration(seconds: 25));
    if (resp.statusCode >= 400) throw ToolException('HTTP ${resp.statusCode} von ${uri.host}');
    final b = BytesBuilder(copy: false);
    await for (final c in resp.timeout(const Duration(seconds: 30))) {
      b.add(c);
      if (b.length > 15 * 1024 * 1024) break;
    }
    return (b.takeBytes(), resp.headers.contentType?.mimeType ?? '');
  } finally {
    client.close(force: true);
  }
}

bool _isZip(Uint8List b) => b.length > 4 && b[0] == 0x50 && b[1] == 0x4B;
bool _isImage(Uint8List b) =>
    b.length > 12 &&
    ((b[0] == 0x89 && b[1] == 0x50) || // PNG
        (b[0] == 0xFF && b[1] == 0xD8) || // JPEG
        (b[0] == 0x47 && b[1] == 0x49) || // GIF
        (b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57)); // WEBP

/// Vorschaubilder einer Vorlagen-Seite: og:image plus bis zu 2 Folien-Vorschauen.
List<String> previewImagesOf(String html, Uri base) {
  final out = <String>[];
  final og = previewImageOf(html, base);
  if (og != null) out.add(og);
  for (final m in RegExp(r'''(?:src|data-src|href)=["']([^"']+?(?:thumb|slide|preview)[^"']*?\.(?:jpe?g|png|webp))''', caseSensitive: false)
      .allMatches(html)) {
    final u = base.resolve(m.group(1)!.replaceAll('&amp;', '&')).toString();
    if (!out.contains(u)) out.add(u);
    if (out.length >= 3) break;
  }
  return out;
}

/// Vorschaubild einer Webseite (og:image / twitter:image), z. B. Vorlagen-Seiten.
String? previewImageOf(String html, Uri base) {
  for (final re in [
    RegExp(r'''<meta[^>]+(?:property|name)=["'](?:og:image|twitter:image)(?::src)?["'][^>]*content=["']([^"']+)''', caseSensitive: false),
    RegExp(r'''<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["'](?:og:image|twitter:image)''', caseSensitive: false),
  ]) {
    final m = re.firstMatch(html);
    if (m != null) return base.resolve(m.group(1)!.replaceAll('&amp;', '&')).toString();
  }
  return null;
}

Future<ResolvedDesign> resolveDesign({
  required ToolContext ctx,
  required String topic,
  String? design,
  String? reference,
  ImageDecoder? decodeImage,
  Uint8List? Function(String name)? readLocal,
  Future<(Uint8List, String)> Function(Uri)? fetch,
}) async {
  final fetchBytes = fetch ?? httpGetBytes;
  final notes = <String>[];
  // Eigenes Design: ausdrücklich gewählt, im Auftrag genannt („in unserem Firmen-CI“) oder als Standard hinterlegt
  final named = DesignLibrary.byId(design) ??
      DesignLibrary.user.where((u) => u.name.length > 2 && ctx.userRequest.toLowerCase().contains(u.name.toLowerCase())).firstOrNull;
  final explicitBuiltIn = design != null && design.trim().isNotEmpty && design != 'auto' && builtInDesigns.any((d) => d.id == design.trim().toLowerCase());
  final own = named ?? (explicitBuiltIn || designReferencesIn(ctx.userRequest).isNotEmpty ? null : DesignLibrary.standard);
  if (own != null && (reference ?? '').trim().isEmpty && !ctx.attachments.any((a) => RegExp(r'\.(pptx|potx|docx|dotx|xlsx)$', caseSensitive: false).hasMatch(a.name))) {
    Uint8List? bytes;
    PptxTemplate? tpl;
    if (own.templatePath != null && File(own.templatePath!).existsSync()) {
      bytes = File(own.templatePath!).readAsBytesSync();
      tpl = PptxTemplate.parse(bytes);
    }
    return ResolvedDesign(own.design.copyWith(source: 'dein Design „${own.name}“'), tpl, notes, templateBytes: tpl == null ? null : bytes);
  }
  final base = explicitBuiltIn ? designById(design) : designForTopic('$topic ${ctx.userRequest}');

  // Vorlagen sammeln: ausdrücklich genannt, Links in der Bitte, passende Anhänge
  final refs = <String>[
    ...?reference?.split(RegExp(r'[\s,;]+')).where((r) => r.trim().isNotEmpty),
    ...designReferencesIn(ctx.userRequest),
    for (final a in ctx.attachments)
      if (RegExp(r'\.(pptx|potx|docx|dotx|xlsx)$', caseSensitive: false).hasMatch(a.name) ||
          (wantsDesign(ctx.userRequest) && RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false).hasMatch(a.name)))
        a.path ?? a.name,
  ];
  final seen = <String>{};
  PptxTemplate? template;
  Uint8List? templateBytes;
  OfficeTheme? office;
  final palette = <String>[];
  var fromImages = 0;
  var networkOk = true;

  Future<void> useBytes(Uint8List bytes, String name) async {
    if (_isZip(bytes)) {
      final lower = name.toLowerCase();
      if (lower.contains('.pptx') || lower.contains('.potx') || (!lower.contains('.docx') && !lower.contains('.xlsx'))) {
        final t = PptxTemplate.parse(bytes);
        if (t != null) {
          if (template == null) templateBytes = bytes;
          template ??= t;
          office ??= t.theme;
          if (!t.wide) notes.add('Hinweis: Die Vorlage ist nicht 16:9 – Folien sind 16:9, Farben und Schriften stammen aus der Vorlage.');
          return;
        }
      }
      office ??= OfficeTheme.fromOffice(readZip(bytes));
      return;
    }
    if (_isImage(bytes) && decodeImage != null) {
      final img = await decodeImage(bytes);
      if (img != null) {
        palette.addAll(extractPalette(img.$3, img.$1, img.$2));
        fromImages++;
      }
    }
  }

  for (final r in refs) {
    if (!seen.add(r.split('#').first) || seen.length > 6) continue;
    try {
      if (r.startsWith('http://') || r.startsWith('https://')) {
        if (!networkOk) continue;
        try {
          await ctx.ensureNetwork('Design-Vorlage laden: $r');
        } on ToolException {
          networkOk = false;
          notes.add('Ohne Internet-Freigabe konnte ich die verlinkten Vorlagen nicht ansehen.');
          continue;
        }
        final uri = Uri.parse(r);
        var (bytes, mime) = await fetchBytes(uri);
        if (!_isImage(bytes) && !_isZip(bytes) && (mime.contains('html') || bytes.length < 3 * 1024 * 1024)) {
          // Vorlagen-Seite: Vorschaubild verwenden
          final imgs = previewImagesOf(String.fromCharCodes(bytes.take(600000)), uri);
          if (imgs.isEmpty) {
            notes.add('Auf ${uri.host} fand ich kein Vorschaubild.');
            continue;
          }
          for (final img in imgs) {
            try {
              final (b, _) = await fetchBytes(Uri.parse(img));
              await useBytes(b, Uri.parse(img).path);
            } catch (_) {}
          }
          continue;
        }
        await useBytes(bytes, uri.path);
      } else {
        final bytes = readLocal?.call(r) ?? (File(r).existsSync() ? File(r).readAsBytesSync() : null);
        if (bytes != null) await useBytes(bytes, r);
      }
    } catch (e) {
      notes.add('Vorlage ${r.length > 60 ? '${r.substring(0, 60)}…' : r} nicht lesbar ($e).');
    }
  }

  var result = base;
  if (office != null) {
    result = designFromOffice(office!, base: base, source: template != null ? 'aus deiner PowerPoint-Vorlage' : 'Farben und Schriften aus deiner Vorlage');
  } else if (palette.isNotEmpty) {
    result = designFromPalette(palette,
        base: base, source: 'Farben aus ${fromImages == 1 ? 'deinem Beispielbild' : 'deinen $fromImages Beispielbildern'}, Stil „${base.name}“');
  }
  return ResolvedDesign(result, template, notes, templateBytes: templateBytes);
}


/// Eigenes Design aus einer Beispieldatei (PowerPoint, Word, Excel oder Bild) anlegen.
/// Ergebnis: Design + (bei PowerPoint) die Vorlage zum Aufbewahren.
Future<(SlideDesign, Uint8List?)?> designFromSample(Uint8List bytes, String fileName,
    {required String name, ImageDecoder? decodeImage, String? id}) async {
  final lower = fileName.toLowerCase();
  SlideDesign? d;
  Uint8List? tpl;
  final base = designById('standard');
  if (_isZip(bytes)) {
    if (lower.endsWith('.pptx') || lower.endsWith('.potx')) {
      final t = PptxTemplate.parse(bytes);
      if (t?.theme != null) {
        d = designFromOffice(t!.theme!, base: base, source: 'aus $fileName');
        tpl = t.wide ? bytes : null;
      }
    }
    if (d == null) {
      final th = OfficeTheme.fromOffice(readZip(bytes));
      if (th != null) d = designFromOffice(th, base: base, source: 'aus $fileName');
    }
  } else if (_isImage(bytes) && decodeImage != null) {
    final img = await decodeImage(bytes);
    if (img != null) d = designFromPalette(extractPalette(img.$3, img.$1, img.$2), base: base, source: 'Farben aus $fileName');
  }
  if (d == null) return null;
  final j = d.toJson()
    ..['id'] = id ?? DesignLibrary.idFor(name)
    ..['name'] = name;
  return (SlideDesign.fromJson(j), tpl);
}
