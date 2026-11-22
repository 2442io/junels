// Browser-Leiste über dem Chat: zeigt, was der Agent im Browser tut.
// Die Seite selbst ist eingeklappt und lässt sich bei Bedarf aufklappen.
// Die Web-Ansicht bleibt immer an derselben Stelle im Fenster (eingeklappt = 0 px hoch),
// damit sie eine echte Größe hat und Seiten richtig aufbaut.

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/browser_service.dart';
import '../state/native_files.dart';

class BrowserDock extends StatelessWidget {
  const BrowserDock({super.key, required this.browser, required this.child});
  final BrowserService browser;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: browser,
      builder: (context, _) {
        if (!browser.created) return child;
        return LayoutBuilder(builder: (context, c) {
          final show = browser.visible;
          final open = show && browser.expanded;
          final pageH = open ? c.maxHeight * 0.48 : 0.0;
          return Column(
            children: [
              if (show) _Bar(browser: browser),
              SizedBox(
                key: const ValueKey('browser-page'),
                height: pageH,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minHeight: open ? pageH : 760,
                    maxHeight: open ? pageH : 760,
                    child: WebViewWidget(controller: browser.controller),
                  ),
                ),
              ),
              if (open) Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant),
              Expanded(key: const ValueKey('browser-chat'), child: child),
            ],
          );
        });
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.browser});
  final BrowserService browser;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final host = (Uri.tryParse(browser.url)?.host ?? '').replaceFirst('www.', '');
    final label = browser.title.isNotEmpty ? browser.title : (host.isEmpty ? 'Browser' : host);
    return Material(
      color: scheme.secondaryContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: browser.toggleExpanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(
                children: [
                  browser.loading
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onSecondaryContainer))
                      : Icon(Icons.travel_explore, size: 20, color: scheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(browser.activity.isNotEmpty ? 'Junels ${browser.activity}' : (browser.loading ? 'Browser lädt …' : 'Browser'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.labelSmall?.copyWith(color: scheme.onSecondaryContainer.withValues(alpha: 0.8))),
                        Text(label,
                            style: t.bodyMedium?.copyWith(color: scheme.onSecondaryContainer),
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  if (browser.expanded) ...[
                    IconButton(
                      tooltip: 'Zurück',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.arrow_back, size: 20, color: scheme.onSecondaryContainer),
                      onPressed: browser.hasPage ? browser.back : null,
                    ),
                    IconButton(
                      tooltip: 'Im normalen Browser öffnen',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.open_in_new, size: 20, color: scheme.onSecondaryContainer),
                      onPressed: browser.hasPage ? () => NativeFiles.openUrl(browser.url) : null,
                    ),
                  ],
                  IconButton(
                    tooltip: browser.expanded ? 'Seite einklappen' : 'Seite anzeigen',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(browser.expanded ? Icons.expand_less : Icons.expand_more, color: scheme.onSecondaryContainer),
                    onPressed: browser.toggleExpanded,
                  ),
                  IconButton(
                    tooltip: 'Leiste schließen',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close, size: 20, color: scheme.onSecondaryContainer),
                    onPressed: browser.hide,
                  ),
                ],
              ),
            ),
          ),
          if (browser.watch != null)
            Container(
              width: double.infinity,
              color: scheme.primaryContainer,
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(children: [
                Icon(Icons.visibility_outlined, size: 18, color: scheme.onPrimaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Junels ${browser.watch!.label} – du bekommst eine Benachrichtigung',
                      style: t.bodySmall?.copyWith(color: scheme.onPrimaryContainer)),
                ),
                TextButton(onPressed: browser.stopWatch, child: const Text('Stopp')),
              ]),
            ),
          if (browser.handOverMessage != null)
            Container(
              width: double.infinity,
              color: scheme.tertiaryContainer,
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.pan_tool_alt_outlined, color: scheme.onTertiaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(browser.handOverMessage!, style: t.bodySmall?.copyWith(color: scheme.onTertiaryContainer)),
                  ),
                  TextButton(onPressed: () => browser.finishHandOver(false), child: const Text('Abbrechen')),
                  FilledButton(onPressed: () => browser.finishHandOver(true), child: const Text('Weiter')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
