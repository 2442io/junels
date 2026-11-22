// KI-Kennzeichnung nach den EU-Vorgaben (AI Act Art. 50, EU-Symbole „AI GENERATED“):
// sichtbares Symbol im Bild selbst – bleibt beim Teilen und Herunterladen erhalten –
// plus maschinenlesbare Metadaten in der PNG-Datei.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'eu_ai_label_data.dart';

Uint8List? _label;

Uint8List get _labelRgba => _label ??= Uint8List.fromList(gzip.decode(base64.decode(euAiGeneratedRgbaGzB64)));

/// Metadaten für KI-erzeugte PNG-Bilder (tEXt).
Map<String, String> aiImageMetadata({String prompt = '', String generator = 'Stable Diffusion'}) => {
      'Software': 'Junels',
      'Description': 'AI generated image (KI-generiert)${prompt.isEmpty ? '' : ': $prompt'}',
      'Comment': 'AI-generated content. Labelled according to EU AI Act Art. 50 (EU icon "AI GENERATED").',
      'Source': generator,
      'AI-Generated': 'true',
    };

/// Stempelt das EU-Symbol „AI GENERATED“ unten rechts in ein RGBA-Bild (in place).
/// Breite ca. 28 % der Bildbreite, mindestens 96 px; mit Rand, damit es nicht abgeschnitten wird.
void stampAiLabel(Uint8List rgba, int w, int h) {
  if (w < 64 || h < 32) return;
  final lw0 = euAiGeneratedWidth, lh0 = euAiGeneratedHeight;
  var lw = (w * 0.28).round().clamp(96, lw0 * 2);
  if (lw > w - 8) lw = w - 8;
  final lh = (lw * lh0 / lw0).round();
  final margin = (w * 0.025).round().clamp(4, 40);
  final x0 = w - lw - margin;
  final y0 = h - lh - margin;
  if (x0 < 0 || y0 < 0) return;
  final src = _labelRgba;
  // Flächen-Mittelung beim Verkleinern (glatte Kanten), bilinear beim Vergrößern
  final sx = lw0 / lw, sy = lh0 / lh;
  for (var y = 0; y < lh; y++) {
    for (var x = 0; x < lw; x++) {
      double r = 0, g = 0, b = 0, a = 0;
      var n = 0;
      final fx0 = x * sx, fy0 = y * sy;
      final fx1 = (x + 1) * sx, fy1 = (y + 1) * sy;
      for (var yy = fy0.floor(); yy < fy1.ceil().clamp(fy0.floor() + 1, lh0); yy++) {
        for (var xx = fx0.floor(); xx < fx1.ceil().clamp(fx0.floor() + 1, lw0); xx++) {
          final i = (yy.clamp(0, lh0 - 1) * lw0 + xx.clamp(0, lw0 - 1)) * 4;
          final al = src[i + 3] / 255.0;
          r += src[i] * al;
          g += src[i + 1] * al;
          b += src[i + 2] * al;
          a += al;
          n++;
        }
      }
      if (a <= 0) continue;
      final alpha = a / n;
      final cr = r / a, cg = g / a, cb = b / a;
      final o = ((y0 + y) * w + (x0 + x)) * 4;
      rgba[o] = (cr * alpha + rgba[o] * (1 - alpha)).round().clamp(0, 255);
      rgba[o + 1] = (cg * alpha + rgba[o + 1] * (1 - alpha)).round().clamp(0, 255);
      rgba[o + 2] = (cb * alpha + rgba[o + 2] * (1 - alpha)).round().clamp(0, 255);
      rgba[o + 3] = 255;
    }
  }
}
