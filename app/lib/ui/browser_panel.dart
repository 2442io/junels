// Browser-Fenster neben bzw. über dem Chat: der Agent klickt, der Nutzer schaut zu oder übernimmt.

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/browser_service.dart';
import '../state/native_files.dart';

class BrowserPanel extends StatelessWidget {
  const BrowserPanel({super.key, required this.browser});
  final BrowserService browser;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: browser,
      builder: (context, _) {
        final host = Uri.tryParse(browser.url)?.host ?? '';
        return Material(
          color: scheme.surfaceContainerLow,
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Zurück',
                      icon: const Icon(Icons.arrow_back, size: 20),
                      onPressed: browser.hasPage ? browser.back : null,
                    ),
                    Icon(Icons.lock_outline, size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        browser.title.isNotEmpty ? '${browser.title} · $host' : (host.isEmpty ? 'Browser' : host),
                        style: t.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Neu laden',
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: browser.hasPage ? browser.reload : null,
                    ),
                    IconButton(
                      tooltip: 'Im normalen Browser öffnen',
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: browser.hasPage ? () => NativeFiles.openUrl(browser.url) : null,
                    ),
                    IconButton(
                      tooltip: 'Browser ausblenden',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: browser.hide,
                    ),
                  ],
                ),
              ),
              if (browser.loading)
                LinearProgressIndicator(value: browser.progress > 0 && browser.progress < 100 ? browser.progress / 100 : null, minHeight: 2)
              else
                const SizedBox(height: 2),
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
                        child: Text(browser.handOverMessage!,
                            style: t.bodySmall?.copyWith(color: scheme.onTertiaryContainer)),
                      ),
                      TextButton(onPressed: () => browser.finishHandOver(false), child: const Text('Abbrechen')),
                      FilledButton(onPressed: () => browser.finishHandOver(true), child: const Text('Weiter')),
                    ],
                  ),
                ),
              Expanded(child: WebViewWidget(controller: browser.controller)),
            ],
          ),
        );
      },
    );
  }
}
