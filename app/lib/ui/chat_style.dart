// Symbole und Farbmarken für Chats und Ordner in der Seitenleiste.

import 'package:flutter/material.dart';

import 'theme.dart';

/// Farbmarken (Schlüssel wird gespeichert)
const tagColors = <String, (String, Color)>{
  'rot': ('Rot', Color(0xFFE5484D)),
  'orange': ('Orange', Color(0xFFF76B15)),
  'gelb': ('Gelb', Color(0xFFE2B203)),
  'gruen': ('Grün', Color(0xFF30A46C)),
  'tuerkis': ('Türkis', Color(0xFF12A594)),
  'blau': ('Blau', Color(0xFF0090FF)),
  'lila': ('Lila', Color(0xFF8E4EC6)),
  'pink': ('Pink', Color(0xFFD6409F)),
  'grau': ('Grau', Color(0xFF8B8D98)),
};

Color? tagColor(String? key) => key == null ? null : tagColors[key]?.$2;

/// Symbole (Schlüssel wird gespeichert)
const chatIcons = <String, IconData>{
  'stern': Icons.star_rounded,
  'herz': Icons.favorite_rounded,
  'flagge': Icons.flag_rounded,
  'blitz': Icons.bolt_rounded,
  'arbeit': Icons.work_rounded,
  'haus': Icons.home_rounded,
  'geld': Icons.euro_rounded,
  'reise': Icons.flight_rounded,
  'einkauf': Icons.shopping_bag_rounded,
  'gesundheit': Icons.local_hospital_rounded,
  'lernen': Icons.school_rounded,
  'code': Icons.code_rounded,
  'idee': Icons.lightbulb_rounded,
  'buch': Icons.menu_book_rounded,
  'musik': Icons.music_note_rounded,
  'sport': Icons.directions_run_rounded,
  'familie': Icons.people_rounded,
  'kalender': Icons.event_rounded,
  'post': Icons.mail_rounded,
  'auto': Icons.directions_car_rounded,
  'amt': Icons.account_balance_rounded,
  'rakete': Icons.rocket_launch_rounded,
  'ziel': Icons.track_changes_rounded,
  'ordner': Icons.folder_rounded,
};

IconData? chatIcon(String? key) => key == null ? null : chatIcons[key];

/// Kleines Symbol bzw. Farbpunkt vor einem Chat/Ordner (null = nichts gesetzt)
Widget? styleMark(BuildContext context, {String? icon, String? color, IconData? fallback, double size = 16}) {
  final col = tagColor(color);
  final ic = chatIcon(icon);
  if (ic == null && col == null) return fallback == null ? null : Icon(fallback, size: size, color: AppColors.of(context).muted);
  if (ic == null) {
    return SizedBox(
      width: size,
      height: size,
      child: Center(child: Container(width: size * 0.6, height: size * 0.6, decoration: BoxDecoration(color: col, shape: BoxShape.circle))),
    );
  }
  return Icon(ic, size: size, color: col ?? AppColors.of(context).muted);
}

/// Symbol und Farbe wählen. Ergebnis: (icon, color) – beide dürfen null sein; null insgesamt = abgebrochen.
Future<(String?, String?)?> pickStyle(BuildContext context, {required String title, String? icon, String? color}) {
  var ic = icon;
  var col = color;
  return showSheet<(String?, String?)>(
    context: context,
    isScrollControlled: true,
    title: title,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final c = AppColors.of(ctx);
        final t = Theme.of(ctx).textTheme;
        final tint = tagColor(col) ?? Theme.of(ctx).colorScheme.onSurface;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text('Farbe', style: t.titleSmall),
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 10, children: [
              _Choice(
                selected: col == null,
                tooltip: 'Keine',
                onTap: () => setState(() => col = null),
                child: Icon(Icons.block, size: 18, color: c.faint),
              ),
              for (final e in tagColors.entries)
                _Choice(
                  selected: col == e.key,
                  tooltip: e.value.$1,
                  onTap: () => setState(() => col = e.key),
                  child: Container(width: 20, height: 20, decoration: BoxDecoration(color: e.value.$2, shape: BoxShape.circle)),
                ),
            ]),
            const SizedBox(height: 18),
            Text('Symbol', style: t.titleSmall),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _Choice(
                selected: ic == null,
                tooltip: 'Keins',
                onTap: () => setState(() => ic = null),
                child: Icon(Icons.block, size: 18, color: c.faint),
              ),
              for (final e in chatIcons.entries)
                _Choice(
                  selected: ic == e.key,
                  tooltip: e.key,
                  onTap: () => setState(() => ic = e.key),
                  child: Icon(e.value, size: 20, color: ic == e.key ? tint : c.muted),
                ),
            ]),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.pop(ctx, (ic, col)), child: const Text('Übernehmen')),
          ]),
        );
      },
    ),
  );
}

class _Choice extends StatelessWidget {
  const _Choice({required this.selected, required this.onTap, required this.child, required this.tooltip});
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected ? c.raised : Colors.transparent,
            border: Border.all(color: selected ? Theme.of(context).colorScheme.primary : c.border, width: selected ? 2 : 1),
          ),
          child: Center(child: child),
        ),
      ),
    );
  }
}
