// Zeichnet Diagramme (Balken, Linie, Torte) mit dart:ui und liefert PNG-Bytes.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:agent_engine/agent_engine.dart';

const _palette = [
  ui.Color(0xFF0E6B66),
  ui.Color(0xFFE07A2E),
  ui.Color(0xFF3E7CB1),
  ui.Color(0xFF8A6BB8),
  ui.Color(0xFF5BA05B),
  ui.Color(0xFFC9504E),
  ui.Color(0xFFD4A72C),
  ui.Color(0xFF5E7472),
];

const _w = 1200.0, _h = 750.0;

ui.Paragraph _text(String s, double size, {ui.Color color = const ui.Color(0xFF222628), bool bold = false, double maxW = 400, ui.TextAlign align = ui.TextAlign.left}) {
  final b = ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: align, maxLines: 2, ellipsis: '…'))
    ..pushStyle(ui.TextStyle(color: color, fontSize: size, fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w400))
    ..addText(s);
  return b.build()..layout(ui.ParagraphConstraints(width: maxW));
}

String _fmt(double v) {
  if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(1)} Mio';
  if (v.abs() >= 10000) return '${(v / 1000).toStringAsFixed(0)}k';
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(v.abs() < 10 ? 2 : 1).replaceAll('.', ',');
}

/// "Schöne" Achsenschritte.
double _niceStep(double range) {
  if (range <= 0) return 1;
  final raw = range / 5;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final n = raw / mag;
  return (n < 1.5 ? 1 : n < 3 ? 2 : n < 7 ? 5 : 10) * mag;
}

Future<Uint8List> renderChart(ChartSpec spec) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec, const ui.Rect.fromLTWH(0, 0, _w, _h));
  c.drawRect(const ui.Rect.fromLTWH(0, 0, _w, _h), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  c.drawParagraph(_text(spec.title, 34, bold: true, maxW: _w - 80), const ui.Offset(40, 28));

  final multi = spec.series.length > 1;
  // Legende
  if (multi || spec.kind == 'pie') {
    final names = spec.kind == 'pie' ? spec.labels : spec.series.map((s) => s.name).toList();
    var lx = 40.0;
    final ly = _h - 46.0;
    for (var i = 0; i < names.length && i < 12; i++) {
      c.drawRRect(ui.RRect.fromLTRBR(lx, ly + 4, lx + 18, ly + 22, const ui.Radius.circular(4)), ui.Paint()..color = _palette[i % _palette.length]);
      final p = _text(names[i], 20, maxW: 220);
      c.drawParagraph(p, ui.Offset(lx + 26, ly));
      lx += 26 + p.longestLine + 30;
      if (lx > _w - 200) break;
    }
  }

  const left = 110.0, top = 110.0, right = _w - 40, bottom = _h - 120;
  if (spec.kind == 'pie') {
    final vals = spec.series.first.values.map((v) => v.abs()).toList();
    final total = vals.fold<double>(0, (a, b) => a + b);
    const center = ui.Offset(_w / 2, (top + bottom) / 2 + 10);
    final r = math.min(right - left, bottom - top) / 2;
    var start = -math.pi / 2;
    for (var i = 0; i < vals.length; i++) {
      final sweep = total == 0 ? 0.0 : vals[i] / total * 2 * math.pi;
      c.drawArc(ui.Rect.fromCircle(center: center, radius: r), start, sweep, true, ui.Paint()..color = _palette[i % _palette.length]);
      c.drawArc(ui.Rect.fromCircle(center: center, radius: r), start, sweep, true,
          ui.Paint()
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = const ui.Color(0xFFFFFFFF));
      if (sweep > 0.25) {
        final mid = start + sweep / 2;
        final pct = '${(vals[i] / total * 100).round()} %';
        final p = _text(pct, 22, bold: true, color: const ui.Color(0xFFFFFFFF), maxW: 120, align: ui.TextAlign.center);
        c.drawParagraph(p, center + ui.Offset(math.cos(mid) * r * 0.65 - 60, math.sin(mid) * r * 0.65 - 13));
      }
      start += sweep;
    }
  } else {
    final all = spec.series.expand((s) => s.values).toList();
    var lo = math.min(0.0, all.reduce(math.min));
    var hi = math.max(0.0, all.reduce(math.max));
    if (hi == lo) hi = lo + 1;
    final step = _niceStep(hi - lo);
    lo = (lo / step).floor() * step;
    hi = (hi / step).ceil() * step;
    double y(double v) => bottom - (v - lo) / (hi - lo) * (bottom - top);
    final grid = ui.Paint()
      ..color = const ui.Color(0xFFE3E8E7)
      ..strokeWidth = 1.5;
    for (var v = lo; v <= hi + step / 2; v += step) {
      c.drawLine(ui.Offset(left, y(v)), ui.Offset(right, y(v)), grid);
      final p = _text(_fmt(v), 20, color: const ui.Color(0xFF6B757F), maxW: left - 20, align: ui.TextAlign.right);
      c.drawParagraph(p, ui.Offset(0, y(v) - 12));
    }
    final n = spec.labels.length;
    final slot = (right - left) / n;
    for (var i = 0; i < n; i++) {
      final p = _text(spec.labels[i], n > 10 ? 15 : 20, color: const ui.Color(0xFF444B50), maxW: slot - 4, align: ui.TextAlign.center);
      c.drawParagraph(p, ui.Offset(left + i * slot + 2, bottom + 12));
    }
    if (spec.kind == 'line') {
      for (var si = 0; si < spec.series.length; si++) {
        final s = spec.series[si];
        final paint = ui.Paint()
          ..color = _palette[si % _palette.length]
          ..strokeWidth = 5
          ..style = ui.PaintingStyle.stroke
          ..strokeJoin = ui.StrokeJoin.round;
        final path = ui.Path();
        for (var i = 0; i < s.values.length && i < n; i++) {
          final pt = ui.Offset(left + (i + 0.5) * slot, y(s.values[i]));
          i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
        }
        c.drawPath(path, paint);
        for (var i = 0; i < s.values.length && i < n; i++) {
          c.drawCircle(ui.Offset(left + (i + 0.5) * slot, y(s.values[i])), 7, ui.Paint()..color = _palette[si % _palette.length]);
        }
      }
    } else {
      final k = spec.series.length;
      final barW = slot * 0.7 / k;
      for (var si = 0; si < k; si++) {
        final s = spec.series[si];
        for (var i = 0; i < s.values.length && i < n; i++) {
          final x = left + i * slot + slot * 0.15 + si * barW;
          final y0 = y(0), y1 = y(s.values[i]);
          c.drawRRect(
              ui.RRect.fromLTRBAndCorners(x, math.min(y0, y1), x + barW - 4, math.max(y0, y1),
                  topLeft: const ui.Radius.circular(6), topRight: const ui.Radius.circular(6)),
              ui.Paint()..color = _palette[(k == 1 ? 0 : si) % _palette.length]);
          if (n * k <= 16) {
            final p = _text(_fmt(s.values[i]), 18, color: const ui.Color(0xFF444B50), maxW: barW + 40, align: ui.TextAlign.center);
            c.drawParagraph(p, ui.Offset(x - 20, math.min(y0, y1) - 26));
          }
        }
      }
    }
    c.drawLine(ui.Offset(left, y(0)), ui.Offset(right, y(0)), ui.Paint()
      ..color = const ui.Color(0xFF8A9590)
      ..strokeWidth = 2);
  }

  final img = await rec.endRecording().toImage(_w.toInt(), _h.toInt());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}
