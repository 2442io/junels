// Farben und Symbole der Benachrichtigungs-Arten – überall gleich (Postfach, Karten, Chips).

import 'package:flutter/material.dart';

import '../state/notifications.dart';
import 'theme.dart';

extension NotifyKindStyle on NotifyKind {
  IconData get icon => switch (this) {
        NotifyKind.aktion => Icons.touch_app,
        NotifyKind.warnung => Icons.warning_amber_rounded,
        NotifyKind.erinnerung => Icons.alarm,
        NotifyKind.ergebnis => Icons.check_circle,
        NotifyKind.info => Icons.info_outline,
        NotifyKind.ruhig => Icons.sync,
      };

  /// (kräftige Farbe für Symbol/Rand, Fläche)
  (Color, Color) colors(BuildContext context) {
    final c = AppColors.of(context);
    return switch (this) {
      NotifyKind.aktion => (c.violet, c.violetSoft),
      NotifyKind.warnung => (c.red, c.redSoft),
      NotifyKind.erinnerung => (c.amber, c.amberSoft),
      NotifyKind.ergebnis => (c.mint, c.mintSoft),
      NotifyKind.info => (c.blue, c.blueSoft),
      NotifyKind.ruhig => (c.muted, c.raised),
    };
  }
}

/// Symbol der Art im farbigen Kreis.
class NotifyBadge extends StatelessWidget {
  const NotifyBadge(this.kind, {super.key, this.size = 36});
  final NotifyKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = kind.colors(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(kind.icon, size: size * 0.55, color: fg),
    );
  }
}

/// Kleiner Chip „Aktion“, „Warnung“ … in der Farbe der Art.
class NotifyChip extends StatelessWidget {
  const NotifyChip(this.kind, {super.key});
  final NotifyKind kind;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = kind.colors(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(kind.icon, size: 12, color: fg),
        const SizedBox(width: 3),
        Text(kind.label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Auswahl der Art („Automatisch“ = Junels entscheidet) – für Prozesse, Beobachtungen, geplante Prompts.
class NotifyKindField extends StatelessWidget {
  const NotifyKindField({super.key, required this.value, required this.onChanged, this.label = 'Art der Benachrichtigung'});
  final String value; // 'auto' oder NotifyKind.name
  final ValueChanged<String> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final kinds = NotifyKind.values.where((k) => k != NotifyKind.ruhig);
    return DropdownButtonFormField<String>(
      initialValue: value == 'auto' || kinds.any((k) => k.name == value) ? value : 'auto',
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(value: 'auto', child: Text('Automatisch')),
        for (final k in kinds)
          DropdownMenuItem(
            value: k.name,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(k.icon, size: 18, color: k.colors(context).$1),
              const SizedBox(width: 8),
              Text(switch (k) {
                NotifyKind.aktion => 'Aktion – du musst etwas tun',
                NotifyKind.warnung => 'Warnung – Fehler/Grenze',
                NotifyKind.erinnerung => 'Erinnerung',
                NotifyKind.ergebnis => 'Ergebnis – fertig',
                _ => 'Info – leise',
              }),
            ]),
          ),
      ],
      onChanged: (v) => onChanged(v ?? 'auto'),
    );
  }
}
