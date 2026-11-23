// Schieberegler „Erledigt“: nach rechts ziehen bestätigt – kein versehentliches Antippen.

import 'package:flutter/material.dart';

class SlideToDone extends StatefulWidget {
  const SlideToDone({super.key, required this.onDone, this.label = 'Zum Erledigen schieben', required this.color, required this.soft});
  final VoidCallback onDone;
  final String label;
  final Color color;
  final Color soft;

  @override
  State<SlideToDone> createState() => _SlideToDoneState();
}

class _SlideToDoneState extends State<SlideToDone> with SingleTickerProviderStateMixin {
  double _x = 0;
  bool _done = false;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(() => setState(() => _x = _from * (1 - _back.value)));
  double _from = 0;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const h = 44.0, knob = 40.0;
    return LayoutBuilder(builder: (context, box) {
      final max = box.maxWidth - knob - 4;
      final p = max <= 0 ? 0.0 : (_x / max).clamp(0.0, 1.0);
      return Semantics(
        button: true,
        label: widget.label,
        onTap: widget.onDone,
        child: Container(
          height: h,
          decoration: BoxDecoration(color: widget.soft, borderRadius: BorderRadius.circular(h / 2)),
          child: Stack(alignment: Alignment.centerLeft, children: [
            Positioned.fill(
              child: Center(
                child: Opacity(
                  opacity: 1 - p,
                  child: Text(widget.label,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: widget.color, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            Positioned(
              left: 2 + _x,
              child: GestureDetector(
                onHorizontalDragUpdate: _done ? null : (d) => setState(() => _x = (_x + d.delta.dx).clamp(0.0, max)),
                onHorizontalDragEnd: _done
                    ? null
                    : (_) {
                        if (p > 0.85) {
                          setState(() {
                            _x = max;
                            _done = true;
                          });
                          widget.onDone();
                        } else {
                          _from = _x;
                          _back.forward(from: 0);
                        }
                      },
                child: Container(
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
                  child: Icon(_done ? Icons.check : Icons.chevron_right, color: Colors.white),
                ),
              ),
            ),
          ]),
        ),
      );
    });
  }
}
