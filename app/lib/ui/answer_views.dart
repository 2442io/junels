// Darstellung einer Antwort im gewählten Ausgabeformat: Karussell, Tabelle, Checkliste, Ablauf oder Text.
// Alles wird aus dem Antworttext bzw. den Werkzeug-Ergebnissen gebaut; klappt das nicht, bleibt es beim Text.

import 'package:agent_engine/agent_engine.dart' show OutputView, cardsFromText, checklistItems, stepsFrom, tableFrom, cardsToTable, introOf, outroOf;
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_scope.dart';
import 'chat_view.dart' show ResultCarousel;
import 'markdown_lite.dart';
import 'theme.dart';

IconData outputViewIcon(String v) => switch (v) {
      OutputView.text => Icons.notes,
      OutputView.cards => Icons.view_carousel_outlined,
      OutputView.table => Icons.table_rows_outlined,
      OutputView.list => Icons.checklist,
      OutputView.steps => Icons.timeline,
      OutputView.chart => Icons.bar_chart,
      OutputView.pdf => Icons.picture_as_pdf_outlined,
      OutputView.word => Icons.description_outlined,
      OutputView.excel => Icons.table_chart_outlined,
      OutputView.pptx => Icons.slideshow_outlined,
      _ => Icons.auto_awesome_mosaic_outlined,
    };

/// Text der Antwort im gewählten Format. [text] ist der bereinigte Antworttext.
class AnswerBody extends StatelessWidget {
  const AnswerBody({super.key, required this.entry, required this.text, required this.networkImages, this.loadImages = true});
  final ChatEntry entry;
  final String text;
  final bool networkImages;
  final bool loadImages;

  Widget _md(String s) => s.trim().isEmpty
      ? const SizedBox.shrink()
      : Padding(padding: const EdgeInsets.only(top: 6), child: MarkdownLite(s, selectable: false, networkImages: networkImages));

  @override
  Widget build(BuildContext context) {
    final view = entry.view;
    final intro = introOf(text), outro = outroOf(text);
    switch (view) {
      case OutputView.cards:
        final cards = entry.cards.isNotEmpty ? entry.cards : cardsFromText(text);
        if (cards.isEmpty) break;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _md(intro),
          ResultCarousel(
            cards: cards,
            loadImages: loadImages,
            onMore: () => AppScope.read(context).pendingInput.value = 'Such bitte weitere Ergebnisse dazu.',
          ),
          _md(outro),
        ]);
      case OutputView.table:
        final rows = tableFrom(text) ?? (entry.cards.isNotEmpty ? cardsToTable(entry.cards) : null);
        if (rows == null) break;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _md(intro),
          _TableCard(entry: entry, rows: rows),
          _md(outro),
        ]);
      case OutputView.list:
        final items = checklistItems(text);
        if (items.length < 2) break;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _md(intro),
          _Checklist(entry: entry, items: items),
          _md(outro),
        ]);
      case OutputView.steps:
        final steps = stepsFrom(text);
        if (steps.length < 2) break;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _md(intro),
          _Timeline(steps: steps),
          _md(outro),
        ]);
    }
    return _md(text);
  }
}

class _TableCard extends StatelessWidget {
  const _TableCard({required this.entry, required this.rows});
  final ChatEntry entry;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = AppColors.of(context);
    final cols = rows.fold<int>(0, (a, r) => r.length > a ? r.length : a);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Ui.r)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              for (var r = 0; r < rows.length; r++)
                TableRow(
                  decoration: BoxDecoration(
                    color: r == 0 ? t.colorScheme.primaryContainer : (r.isEven ? t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4) : null),
                  ),
                  children: [
                    for (var i = 0; i < cols; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: Text(i < rows[r].length ? rows[r][i] : '',
                              style: t.textTheme.bodyMedium?.copyWith(fontWeight: r == 0 ? FontWeight.w600 : null)),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            icon: const Icon(Icons.table_chart_outlined, size: 18),
            label: const Text('Als Excel speichern'),
            onPressed: () async {
              final m = ScaffoldMessenger.of(context);
              final path = await AppScope.read(context).tableToExcel(entry);
              m.showSnackBar(SnackBar(content: Text(path == null ? 'Keine Tabelle gefunden' : 'Excel-Datei erstellt')));
            },
          ),
        ),
      ]),
    );
  }
}

class _Checklist extends StatelessWidget {
  const _Checklist({required this.entry, required this.items});
  final ChatEntry entry;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final done = entry.checked.where((i) => i < items.length).length;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(border: Border.all(color: c.border), borderRadius: BorderRadius.circular(Ui.r)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Row(children: [
            Expanded(child: LinearProgressIndicator(value: items.isEmpty ? 0 : done / items.length, minHeight: 5, borderRadius: BorderRadius.circular(9))),
            const SizedBox(width: 10),
            Text('$done/${items.length} erledigt', style: Theme.of(context).textTheme.labelMedium),
          ]),
        ),
        for (var i = 0; i < items.length; i++)
          CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: entry.checked.contains(i),
            onChanged: (_) => app.toggleChecked(entry, i),
            title: Text(items[i],
                style: entry.checked.contains(i)
                    ? TextStyle(decoration: TextDecoration.lineThrough, color: c.muted)
                    : null),
          ),
      ]),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.steps});
  final List<(String, String)> steps;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final accent = t.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(children: [
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 34,
                child: Column(children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                    child: Text('${i + 1}', style: TextStyle(color: t.colorScheme.onPrimary, fontWeight: FontWeight.w600, fontSize: 12)),
                  ),
                  if (i < steps.length - 1) Expanded(child: Container(width: 2, color: accent.withValues(alpha: 0.3))),
                ]),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14, top: 3),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(steps[i].$1, style: t.textTheme.titleSmall),
                    if (steps[i].$2.isNotEmpty) Text(steps[i].$2, style: t.textTheme.bodyMedium),
                  ]),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// Format-Wahl über der Eingabe (für den ganzen Chat; Dateien nur für die nächste Antwort).
class OutputViewMenu extends StatelessWidget {
  const OutputViewMenu({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final view = app.current?.view ?? '';
    final active = view.isNotEmpty;
    return PopupMenuButton<String>(
      tooltip: 'Ausgabe: ${OutputView.labels[view]}',
      onSelected: (v) => app.setChatView(v),
      itemBuilder: (_) => [
        for (final e in OutputView.labels.entries) ...[
          if (e.key == OutputView.pdf) const PopupMenuDivider(),
          PopupMenuItem(
            value: e.key,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(outputViewIcon(e.key)),
              title: Text(e.value),
              subtitle: Text(OutputView.isFile(e.key) ? '${OutputView.hints[e.key]} – nur nächste Antwort' : OutputView.hints[e.key]!),
              trailing: view == e.key ? Icon(Icons.check, color: c.mint, size: 18) : null,
            ),
          ),
        ],
      ],
      child: Container(
        height: 38,
        width: compact ? 38 : null,
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
        decoration: BoxDecoration(
          color: active ? scheme.primaryContainer : scheme.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: active ? scheme.primary.withValues(alpha: 0.5) : c.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(outputViewIcon(view), size: 18, color: active ? scheme.primary : scheme.onSurface),
          if (!compact) ...[
            const SizedBox(width: 6),
            Text(active ? OutputView.labels[view]! : 'Format',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: active ? scheme.primary : scheme.onSurface)),
          ],
        ]),
      ),
    );
  }
}

/// Auswahl des Ausgabeformats in Formularen (Skill, Ablauf-Baustein, Beobachtung)
class OutputViewField extends StatelessWidget {
  const OutputViewField({super.key, required this.value, required this.onChanged, this.label = 'Ausgabe', this.helper});
  final String value;
  final ValueChanged<String> onChanged;
  final String label;
  final String? helper;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
        initialValue: OutputView.valid(value) ? value : '',
        isExpanded: true,
        decoration: InputDecoration(labelText: label, helperText: helper ?? OutputView.hints[OutputView.valid(value) ? value : '']),
        items: [
          for (final e in OutputView.labels.entries)
            DropdownMenuItem(
              value: e.key,
              child: Row(children: [
                Icon(outputViewIcon(e.key), size: 18),
                const SizedBox(width: 8),
                Flexible(child: Text(e.value, overflow: TextOverflow.ellipsis)),
              ]),
            ),
        ],
        onChanged: (v) => onChanged(v ?? ''),
      );
}
