// Fortschritt eines Web-Jobs: Schritte, Status, Pause/Fortsetzen/Abbrechen, Browser ansehen, Nachweis.

import 'package:agent_engine/agent_engine.dart' show WebJob, SitePolicy;
import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/native_files.dart';
import 'theme.dart';

class JobPanel extends StatelessWidget {
  const JobPanel({super.key, required this.jobId});
  final String jobId;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.webJobs, app.browser]),
      builder: (context, _) {
        final j = app.webJobs.byId(jobId);
        final t = Theme.of(context).textTheme;
        final c = AppColors.of(context);
        if (j == null) return Text('Dieser Job ist nicht mehr gespeichert.', style: t.bodySmall?.copyWith(color: c.muted));
        final total = j.steps.length;
        final color = switch (j.status) {
          'problem' => c.red,
          'wartet' => c.amber,
          'fertig' => c.mint,
          'abgebrochen' || 'pausiert' => c.muted,
          _ => c.violet,
        };
        final browser = app.browser;
        final host = SitePolicy.hostOf(browser.url);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            if (j.active)
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color))
            else
              Icon(
                  switch (j.status) {
                    'fertig' => Icons.check_circle,
                    'problem' => Icons.error_outline,
                    'abgebrochen' => Icons.cancel_outlined,
                    _ => Icons.pause_circle_outline,
                  },
                  size: 18,
                  color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(j.progressLabel, style: t.labelLarge?.copyWith(color: color))),
            if (j.macro) StatusChip('vorgemacht', color: c.blue, icon: Icons.play_circle_outline, dense: true),
          ]),
          if (total > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: j.status == 'plant' ? null : (j.done / total).clamp(0, 1).toDouble(),
                minHeight: 5,
                color: color,
                backgroundColor: c.raised,
              ),
            ),
          ],
          const SizedBox(height: 8),
          for (var i = 0; i < j.steps.length; i++) _step(context, j, i),
          // Seite, auf der Junels gerade arbeitet
          if (j.active && host.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                Icon(Icons.public, size: 14, color: c.faint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('${browser.title.isEmpty ? host : browser.title} · $host',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: c.faint)),
                ),
              ]),
            ),
          if (j.status == 'wartet' && browser.handOverMessage != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: c.amberSoft, borderRadius: BorderRadius.circular(10)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(browser.handOverMessage!, style: t.bodySmall),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_browser, size: 18),
                    label: const Text('Browser öffnen'),
                    onPressed: () => _showBrowser(app),
                  ),
                  FilledButton(onPressed: () => browser.finishHandOver(true), child: const Text('Erledigt – weiter')),
                ]),
              ]),
            ),
          if (j.status == 'problem' && j.problem.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(j.problem, style: t.bodySmall?.copyWith(color: c.red)),
            ),
          if (j.status == 'fertig' && j.proofUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: InkWell(
                onTap: () => NativeFiles.openUrl(j.proofUrl),
                child: Row(children: [
                  Icon(Icons.verified_outlined, size: 16, color: c.mint),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Nachweis: ${j.proofTitle.isEmpty ? SitePolicy.hostOf(j.proofUrl) : j.proofTitle}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(decoration: TextDecoration.underline)),
                  ),
                ]),
              ),
            ),
          const SizedBox(height: 4),
          Wrap(spacing: 4, children: [
            if (j.active) ...[
              TextButton.icon(onPressed: () => app.webJobs.pause(j), icon: const Icon(Icons.pause, size: 18), label: const Text('Pause')),
              TextButton.icon(onPressed: () => _showBrowser(app), icon: const Icon(Icons.visibility_outlined, size: 18), label: const Text('Zusehen')),
            ],
            if (j.status == 'pausiert' || j.status == 'problem')
              TextButton.icon(onPressed: () => app.webJobs.resume(j), icon: const Icon(Icons.play_arrow, size: 18), label: const Text('Fortsetzen')),
            if (!j.finished)
              TextButton.icon(
                  onPressed: () => app.webJobs.cancel(j),
                  icon: Icon(Icons.stop, size: 18, color: c.red),
                  label: Text('Abbrechen', style: TextStyle(color: c.red))),
          ]),
        ]);
      },
    );
  }

  /// Browser über der Sammlung aufklappen
  static void _showBrowser(AppController app) {
    app.browser
      ..conversationId = AppController.feedId
      ..dismissed = false
      ..expanded = true;
    app.openFeed();
  }

  Widget _step(BuildContext context, WebJob j, int i) {
    final s = j.steps[i];
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final icon = switch (s.status) {
      'ok' => Icon(Icons.check_circle, size: 16, color: c.mint),
      'problem' => Icon(Icons.error, size: 16, color: c.red),
      'läuft' => SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: c.violet)),
      'übersprungen' => Icon(Icons.remove_circle_outline, size: 16, color: c.faint),
      _ => Icon(Icons.radio_button_unchecked, size: 16, color: c.faint),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: SizedBox(width: 18, child: Center(child: icon))),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.text,
                style: t.bodyMedium?.copyWith(
                    color: s.status == 'offen' ? c.muted : null, fontWeight: s.status == 'läuft' ? FontWeight.w600 : null)),
            if (s.note.isNotEmpty && s.status != 'offen')
              Text(s.note, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: c.faint)),
          ]),
        ),
      ]),
    );
  }
}
