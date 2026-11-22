// Begleit-Karte über dem Chat: Ziel, Plan mit Häkchen, aktueller Schritt, Beobachtung, Vorlage speichern.

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/guide.dart';
import 'theme.dart';

class GuideCard extends StatefulWidget {
  const GuideCard({super.key});

  @override
  State<GuideCard> createState() => _GuideCardState();
}

class _GuideCardState extends State<GuideCard> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final conv = app.current;
    final g = Guide.of(conv);
    if (conv == null || g == null) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final cur = g.current;
    final total = g.steps.length;
    final watch = app.browser.watch;
    final busy = app.running && app.runningConvId == conv.id;

    Widget stepRow(int i) {
      final s = g.steps[i];
      final (icon, color) = switch (s.status) {
        'erledigt' => (Icons.check_circle, c.mint),
        'aktiv' => (Icons.play_circle_fill, c.amber),
        _ => (Icons.radio_button_unchecked, c.faint),
      };
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${i + 1}. ${s.text}',
              style: t.bodyMedium?.copyWith(
                color: s.status == 'erledigt' ? c.muted : scheme.onSurface,
                fontWeight: s.status == 'aktiv' ? FontWeight.w600 : null,
                decoration: s.status == 'erledigt' ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          if (s.you)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: c.violetSoft, borderRadius: BorderRadius.circular(99)),
              child: Text('du', style: t.labelSmall?.copyWith(color: c.violet)),
            ),
        ]),
      );
    }

    final headline = !g.active
        ? 'Geschafft · ${g.goal}'
        : cur >= 0
            ? 'Schritt ${cur + 1}/$total · ${g.steps[cur].text}'
            : g.goal;

    return Material(
      color: scheme.surface,
      child: Container(
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Row(children: [
              busy
                  ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: c.amber))
                  : Icon(g.active ? Icons.explore_outlined : Icons.task_alt, size: 20, color: g.active ? c.amber : c.mint),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('Begleitung${busy && app.browser.activity.isNotEmpty ? ' · ${app.browser.activity}' : ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: t.labelSmall?.copyWith(color: c.muted)),
                  Text(headline, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ]),
              ),
              if (total > 0) MonoText('${g.done}/$total', color: c.muted),
              Icon(_open ? Icons.expand_less : Icons.expand_more, color: c.muted),
            ]),
          ),
          if (total > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(minHeight: 3, value: g.done / total, color: c.mint, backgroundColor: c.raised),
              ),
            ),
          if (_open) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < total; i++) stepRow(i)]),
              ),
            ),
            if (watch != null || g.note.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 6, right: 8),
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                decoration: BoxDecoration(color: c.blueSoft, borderRadius: BorderRadius.circular(Ui.r)),
                child: Row(children: [
                  Icon(watch != null ? Icons.visibility_outlined : Icons.notifications_active_outlined, size: 18, color: c.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(watch != null ? 'Junels ${watch.label}' : g.note,
                        style: t.bodySmall?.copyWith(color: scheme.onSurface)),
                  ),
                  if (watch != null)
                    TextButton(onPressed: app.browser.stopWatch, child: const Text('Stopp')),
                ]),
              ),
            const SizedBox(height: 4),
            Wrap(spacing: 4, children: [
              if (g.active)
                TextButton.icon(
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: const Text('Weiter'),
                  onPressed: busy ? null : () => app.send('Weiter mit dem nächsten Schritt.'),
                ),
              TextButton.icon(
                icon: const Icon(Icons.travel_explore, size: 18),
                label: const Text('Seite'),
                onPressed: app.browser.created
                    ? () {
                        if (!app.browser.expanded) app.browser.toggleExpanded();
                        app.browser.show();
                      }
                    : null,
              ),
              TextButton.icon(
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('Als Vorlage'),
                onPressed: () async {
                  final m = ScaffoldMessenger.of(context);
                  final r = await app.saveGuideTemplate(conv);
                  m.showSnackBar(SnackBar(content: Text(r)));
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.close, size: 18),
                label: Text(g.active ? 'Beenden' : 'Schließen'),
                onPressed: () => app.endGuide(conv),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
