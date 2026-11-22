// Designs für Präsentationen und Dokumente: eingebaute Stile passend zum Thema,
// Farben aus Beispielbildern oder Office-Vorlagen.

import 'dart:math' as math;
import 'dart:typed_data';

import 'office_read.dart';
import 'pdf_writer.dart' show DocTheme;

/// Dekor-Motiv auf den Folien (eigene einfache Formen, keine fremden Grafiken).
enum DesignMotif { none, travel, waves, dots, corners, lines }

class SlideDesign {
  const SlideDesign({
    required this.id,
    required this.name,
    required this.primary,
    required this.secondary,
    this.accent,
    this.background = 'FFFFFF',
    this.text = '222628',
    this.muted = '6B757F',
    this.titleText = 'FFFFFF',
    this.light,
    this.font = 'Calibri',
    this.headFont,
    this.motif = DesignMotif.none,
    this.journey = false,
    this.source,
  });

  final String id;
  final String name;

  /// Hauptfarbe: Titel, Balken, Aufzählungszeichen (Hex ohne #)
  final String primary;
  final String secondary;
  final String? accent;
  final String background;
  final String text;
  final String muted;
  final String titleText;

  /// Helle Fläche (Tabellenzeilen, Bänder)
  final String? light;
  final String font;
  final String? headFont;
  final DesignMotif motif;

  /// Reise-/Ablaufleiste unten auf jeder Folie (roter Faden)
  final bool journey;

  /// Woher das Design stammt (für die Rückmeldung an den Nutzer)
  final String? source;

  String get lightColor => light ?? mix(primary, 'FFFFFF', 0.9);
  String get accentColor => accent ?? secondary;
  String get heading => headFont ?? font;

  SlideDesign copyWith({String? source, DesignMotif? motif, bool? journey, String? name, String? font, String? headFont}) =>
      SlideDesign(
        id: id,
        name: name ?? this.name,
        primary: primary,
        secondary: secondary,
        accent: accent,
        background: background,
        text: text,
        muted: muted,
        titleText: titleText,
        light: light,
        font: font ?? this.font,
        headFont: headFont ?? this.headFont,
        motif: motif ?? this.motif,
        journey: journey ?? this.journey,
        source: source ?? this.source,
      );

  static List<double> _rgb(String hex) => [
        int.parse(hex.substring(0, 2), radix: 16) / 255,
        int.parse(hex.substring(2, 4), radix: 16) / 255,
        int.parse(hex.substring(4, 6), radix: 16) / 255,
      ];

  /// Farben für die PDF-Ausgabe.
  DocTheme get pdfTheme => DocTheme(accent: _rgb(primary), text: _rgb(text), muted: _rgb(muted), light: _rgb(lightColor));

  /// theme1.xml für PowerPoint (Farben + Schriften).
  String themeXml() => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="$name">'
      '<a:themeElements><a:clrScheme name="$name">'
      '<a:dk1><a:srgbClr val="$text"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>'
      '<a:dk2><a:srgbClr val="${mix(primary, '000000', 0.35)}"/></a:dk2><a:lt2><a:srgbClr val="$lightColor"/></a:lt2>'
      '<a:accent1><a:srgbClr val="$primary"/></a:accent1><a:accent2><a:srgbClr val="$secondary"/></a:accent2>'
      '<a:accent3><a:srgbClr val="$accentColor"/></a:accent3><a:accent4><a:srgbClr val="${mix(primary, secondary, 0.5)}"/></a:accent4>'
      '<a:accent5><a:srgbClr val="${mix(secondary, 'FFFFFF', 0.35)}"/></a:accent5><a:accent6><a:srgbClr val="$muted"/></a:accent6>'
      '<a:hlink><a:srgbClr val="$primary"/></a:hlink><a:folHlink><a:srgbClr val="$muted"/></a:folHlink></a:clrScheme>'
      '<a:fontScheme name="$name"><a:majorFont><a:latin typeface="$heading"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
      '<a:minorFont><a:latin typeface="$font"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>'
      '<a:fmtScheme name="$name"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>'
      '<a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
      '<a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
      '<a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>'
      '<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>'
      '<a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>'
      '<a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements>'
      '<a:objectDefaults/><a:extraClrSchemeLst/></a:theme>';
}

// ------------------------------------------------------------------ Farben

int _c(String hex, int i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
String _hex(int r, int g, int b) =>
    [r, g, b].map((v) => v.clamp(0, 255).toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// Mischt zwei Farben (t = Anteil von b).
String mix(String a, String b, double t) =>
    _hex((_c(a, 0) + (_c(b, 0) - _c(a, 0)) * t).round(), (_c(a, 1) + (_c(b, 1) - _c(a, 1)) * t).round(),
        (_c(a, 2) + (_c(b, 2) - _c(a, 2)) * t).round());

double luminance(String hex) {
  double ch(int v) {
    final s = v / 255;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * ch(_c(hex, 0)) + 0.7152 * ch(_c(hex, 1)) + 0.0722 * ch(_c(hex, 2));
}

double contrast(String a, String b) {
  final la = luminance(a), lb = luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

double _saturation(String hex) {
  final r = _c(hex, 0) / 255, g = _c(hex, 1) / 255, b = _c(hex, 2) / 255;
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  if (mx == 0) return 0;
  return (mx - mn) / mx;
}

double _hue(String hex) {
  final r = _c(hex, 0) / 255, g = _c(hex, 1) / 255, b = _c(hex, 2) / 255;
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final d = mx - mn;
  if (d == 0) return 0;
  double h;
  if (mx == r) {
    h = ((g - b) / d) % 6;
  } else if (mx == g) {
    h = (b - r) / d + 2;
  } else {
    h = (r - g) / d + 4;
  }
  return h * 60;
}

/// Dunkelt eine Farbe ab, bis sie auf Weiß gut lesbar ist (Kontrast ≥ [min]).
String readableOnWhite(String hex, {double min = 4.5}) {
  var c = hex;
  for (var i = 0; i < 12 && contrast(c, 'FFFFFF') < min; i++) {
    c = mix(c, '000000', 0.12);
  }
  return c;
}

/// Hauptfarben eines Bildes (RGBA) – häufigste Farbgruppen, ähnliche zusammengefasst.
List<String> extractPalette(Uint8List rgba, int w, int h, {int count = 6}) {
  final buckets = <int, List<int>>{}; // Schlüssel: 4 Bit je Kanal → [n, r, g, b]
  final step = math.max(1, (w * h / 20000).floor());
  for (var i = 0; i < w * h; i += step) {
    final o = i * 4;
    if (o + 3 >= rgba.length || rgba[o + 3] < 128) continue;
    final r = rgba[o], g = rgba[o + 1], b = rgba[o + 2];
    final k = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4);
    final e = buckets.putIfAbsent(k, () => [0, 0, 0, 0]);
    e[0]++;
    e[1] += r;
    e[2] += g;
    e[3] += b;
  }
  final sorted = buckets.values.toList()..sort((a, b) => b[0].compareTo(a[0]));
  final out = <String>[];
  for (final e in sorted) {
    final hex = _hex(e[1] ~/ e[0], e[2] ~/ e[0], e[3] ~/ e[0]);
    // zu ähnlich zu einer schon gewählten Farbe?
    if (out.any((o) => _dist(o, hex) < 60)) continue;
    out.add(hex);
    if (out.length >= count * 2) break;
  }
  return out.take(math.max(count, 8)).toList();
}

double _dist(String a, String b) {
  final dr = _c(a, 0) - _c(b, 0), dg = _c(a, 1) - _c(b, 1), db = _c(a, 2) - _c(b, 2);
  return math.sqrt(dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11) * 1.7;
}

/// Design aus Bildfarben: kräftigste Farbe als Hauptfarbe, zweite deutlich andere als Akzent.
SlideDesign designFromPalette(List<String> palette, {required SlideDesign base, String? source}) {
  if (palette.isEmpty) return base;
  final colorful = [for (final p in palette) if (_saturation(p) > 0.25 && luminance(p) > 0.03 && luminance(p) < 0.8) p]
    ..sort((a, b) => (_saturation(b) * (1 - (luminance(b) - 0.25).abs())).compareTo(_saturation(a) * (1 - (luminance(a) - 0.25).abs())));
  if (colorful.isEmpty) return base.copyWith(source: source);
  final primary = readableOnWhite(colorful.first, min: 3.5);
  final second = colorful.skip(1).firstWhere((c) => (_hue(c) - _hue(colorful.first)).abs() % 360 > 35, orElse: () => base.secondary);
  // helle Fläche: hellste ungesättigte Farbe aus dem Bild (z. B. Sand, Creme)
  final lights = [for (final p in palette) if (luminance(p) > 0.75) p]..sort((a, b) => luminance(b).compareTo(luminance(a)));
  final light = lights.isEmpty ? null : mix(lights.first, 'FFFFFF', 0.35);
  return SlideDesign(
    id: '${base.id}-bild',
    name: '${base.name} (Farben aus deiner Vorlage)',
    primary: primary,
    secondary: second,
    accent: colorful.length > 2 ? colorful[2] : null,
    background: light != null && contrast(base.text, light) > 9 ? mix(light, 'FFFFFF', 0.6) : 'FFFFFF',
    text: base.text,
    muted: base.muted,
    light: light,
    font: base.font,
    headFont: base.headFont,
    motif: base.motif,
    journey: base.journey,
    source: source,
  );
}

/// Design aus einem Office-Design (Word/Excel/PowerPoint).
SlideDesign designFromOffice(OfficeTheme t, {required SlideDesign base, String? source}) {
  final a1 = t['accent1'];
  if (a1 == null) return base.copyWith(source: source);
  return SlideDesign(
    id: 'office',
    name: t.name == null ? 'Deine Vorlage' : 'Vorlage „${t.name}“',
    primary: readableOnWhite(a1, min: 3.5),
    secondary: t['accent2'] ?? base.secondary,
    accent: t['accent3'],
    text: t['dk1'] != null && contrast(t['dk1']!, 'FFFFFF') > 7 ? t['dk1']! : base.text,
    light: t['lt2'] != null && luminance(t['lt2']!) > 0.75 ? t['lt2'] : null,
    font: t.minorFont ?? base.font,
    headFont: t.majorFont,
    motif: base.motif,
    journey: base.journey,
    source: source,
  );
}

// ------------------------------------------------------- eingebaute Designs

const builtInDesigns = <SlideDesign>[
  SlideDesign(id: 'standard', name: 'Standard', primary: '0E6B66', secondary: 'E07A2E', motif: DesignMotif.lines),
  SlideDesign(
      id: 'reise',
      name: 'Reise',
      primary: '0B6E8E',
      secondary: 'F2A541',
      accent: 'E5704B',
      light: 'FBF3E4',
      background: 'FFFDF8',
      font: 'Trebuchet MS',
      headFont: 'Georgia',
      motif: DesignMotif.travel,
      journey: true),
  SlideDesign(
      id: 'natur', name: 'Natur', primary: '3D7A3A', secondary: 'C8A15A', light: 'EEF4E8', font: 'Calibri', headFont: 'Georgia', motif: DesignMotif.waves),
  SlideDesign(id: 'business', name: 'Business', primary: '1F3A60', secondary: '3E86C6', light: 'EDF2F8', font: 'Calibri', motif: DesignMotif.corners),
  SlideDesign(id: 'technik', name: 'Technik', primary: '3A3FD1', secondary: '18B6C4', light: 'EEF0FC', font: 'Segoe UI', motif: DesignMotif.dots),
  SlideDesign(id: 'warm', name: 'Warm', primary: 'B5462E', secondary: 'E9A23B', light: 'FBEFE6', font: 'Calibri', headFont: 'Georgia', motif: DesignMotif.waves),
  SlideDesign(id: 'elegant', name: 'Elegant', primary: '2D2A32', secondary: 'B08D57', light: 'F4F1EC', font: 'Garamond', headFont: 'Georgia', motif: DesignMotif.lines),
  SlideDesign(id: 'bildung', name: 'Bildung', primary: '6A3FA0', secondary: 'F2B134', light: 'F3EEF9', font: 'Calibri', motif: DesignMotif.dots),
  SlideDesign(id: 'gesundheit', name: 'Gesundheit', primary: '1E7F8C', secondary: '7CC6A3', light: 'EAF6F4', font: 'Calibri', motif: DesignMotif.waves),
];

SlideDesign designById(String id) =>
    builtInDesigns.firstWhere((d) => d.id == id.toLowerCase().trim(), orElse: () => builtInDesigns.first);

final _topics = <String, RegExp>{
  'reise': RegExp(r'reise|urlaub|travel|tour\b|touris|flug|hotel|ausflug|trip|journey|städtetrip|wander|kreuzfahrt|roadtrip|ferien|destination|sightseeing',
      caseSensitive: false),
  'natur': RegExp(r'natur|umwelt|nachhaltig|klima|wald|garten|pflanz|ökolog|bio\b|landwirtschaft', caseSensitive: false),
  'technik': RegExp(r'\bki\b|künstliche intelligenz|software|technik|technolog|digital|daten|cloud|cyber|\bit\b|app\b|startup', caseSensitive: false),
  'business': RegExp(r'unternehmen|strategie|quartal|umsatz|finanz|business|vertrieb|markt|investor|bilanz|management', caseSensitive: false),
  'bildung': RegExp(r'schule|unterricht|lern|bildung|kurs|workshop|seminar|schulung|universität|studium', caseSensitive: false),
  'gesundheit': RegExp(r'gesundheit|medizin|pflege|ernährung|fitness|sport|therapie|klinik', caseSensitive: false),
  'warm': RegExp(r'essen|kochen|rezept|restaurant|wein|café|genuss|feier|hochzeit|familie', caseSensitive: false),
};

/// Passendes eingebautes Design zum Thema (z. B. „Präsentation über unsere Reise nach Lissabon“ → Reise).
SlideDesign designForTopic(String text) {
  var best = builtInDesigns.first;
  var bestHits = 0;
  for (final e in _topics.entries) {
    final hits = e.value.allMatches(text).length;
    if (hits > bestHits) {
      bestHits = hits;
      best = designById(e.key);
    }
  }
  return best;
}

/// Adressen und Dateinamen, die als Design-Vorlage gemeint sein könnten.
List<String> designReferencesIn(String text) => [
      for (final m in RegExp(r'https?://[^\s<>"\x27)]+').allMatches(text))
        if (RegExp(r'\.(png|jpe?g|webp|gif|pptx|potx|docx|xlsx)(\?|$)', caseSensitive: false).hasMatch(m.group(0)!) ||
            RegExp(r'slidesgo|canva|template|vorlage|design|theme|behance|dribbble|pinterest|freepik', caseSensitive: false).hasMatch(m.group(0)!))
          m.group(0)!.replaceAll(RegExp(r'[.,;:!]+$'), ''),
    ];

/// Hat der Nutzer ein eigenes Design gewünscht?
bool wantsDesign(String text) =>
    RegExp(r'design|vorlage|template|stil|look|aussehen|farben|layout|passend zu|soll .* passen', caseSensitive: false).hasMatch(text);
