// Freigabeliste: Welche Apps darf Junels öffnen und steuern?

import 'package:flutter/material.dart';

import '../state/app_control.dart';
import '../state/app_scope.dart';
import 'theme.dart';

Future<void> openAppsPage(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppsPage()));

class AppsPage extends StatefulWidget {
  const AppsPage({super.key});
  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  Future<void> _add() async {
    final app = AppScope.read(context);
    List<(String, String)> installed;
    try {
      installed = await app.deviceBridge.listApps();
    } catch (_) {
      installed = const [];
    }
    if (!mounted) return;
    final have = app.allowedApps.map((a) => a.id).toSet();
    final filter = TextEditingController();
    final picked = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final q = filter.text.toLowerCase();
          final list = installed.where((a) => !have.contains(a.$2) && (q.isEmpty || a.$1.toLowerCase().contains(q))).toList();
          return AlertDialog(
            title: const Text('App freigeben'),
            content: SizedBox(
              width: 420,
              height: 420,
              child: Column(children: [
                TextField(
                  controller: filter,
                  autofocus: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'z. B. Spotify'),
                  onChanged: (_) => setS(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: installed.isEmpty
                      ? const Center(child: Text('Keine Apps gefunden.'))
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (_, i) => ListTile(
                            dense: true,
                            title: Text(list[i].$1),
                            subtitle: Text(list[i].$2, style: const TextStyle(fontSize: 11)),
                            trailing: sensitiveApp('${list[i].$1} ${list[i].$2}') ? const Icon(Icons.shield_outlined, size: 18) : null,
                            onTap: () => Navigator.pop(ctx, list[i]),
                          ),
                        ),
                ),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen'))],
          );
        },
      ),
    );
    filter.dispose();
    if (picked == null) return;
    final a = AllowedApp(name: picked.$1, id: picked.$2);
    // Musik-/Video-Apps: Suchen gleich erlauben; Bank/Shop nie
    a.links = !a.sensitive && searchLinkFor(a.id, 'x', android: true) != null;
    await app.saveAllowedApps([...app.allowedApps, a]);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final list = app.allowedApps;
    Future<void> save() => app.saveAllowedApps(list);
    return Scaffold(
      appBar: AppBar(title: const Text('Apps steuern')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('App freigeben')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  'Junels darf nur Apps aus dieser Liste öffnen. Möglich sind: App öffnen, Wiedergabe steuern '
                  '(Abspielen, Pause, nächster/vorheriger Titel) und – wenn erlaubt – eine Suche in der App öffnen. '
                  'Sag z. B. „Spiel Musik auf Spotify“, „Pause“ oder „Such auf Spotify nach Jazz“.',
                  style: t.bodySmall,
                ),
                const SizedBox(height: 10),
                Panel(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.shield_outlined, color: c.mint),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Immer geschützt: Junels tippt nichts in fremden Apps, kann nichts kaufen, bestellen, abonnieren oder bezahlen. '
                        'Suchen mit Kauf-/Zahlungsbezug werden abgelehnt. Bank-, Bezahl- und Shopping-Apps lassen sich nur öffnen. '
                        'Alles läuft lokal auf diesem Gerät.',
                        style: t.bodySmall,
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                if (list.isEmpty)
                  const Panel(child: EmptyHint(icon: Icons.apps, title: 'Noch keine App freigegeben', text: 'Tippe auf „App freigeben“, z. B. für Spotify.')),
                for (final a in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Panel(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Flexible(child: Text(a.name, style: t.titleSmall, overflow: TextOverflow.ellipsis)),
                                if (a.sensitive) ...[
                                  const SizedBox(width: 8),
                                  StatusChip('nur öffnen', color: c.amber, soft: c.amberSoft, dense: true),
                                ],
                              ]),
                              MonoText(a.id, size: 11),
                            ]),
                          ),
                          IconButton(
                            tooltip: 'Entfernen',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => app.saveAllowedApps([for (final x in list) if (x.id != a.id) x]),
                          ),
                        ]),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Suchen in der App öffnen'),
                          subtitle: Text(a.sensitive
                              ? 'Bei Bank/Shop/Zahlung gesperrt'
                              : (searchLinkFor(a.id, 'x', android: true) == null ? 'Für diese App nicht verfügbar' : 'z. B. „Such nach Jazz“')),
                          value: a.links && !a.sensitive,
                          onChanged: a.sensitive || searchLinkFor(a.id, 'x', android: true) == null
                              ? null
                              : (v) {
                                  a.links = v;
                                  save();
                                },
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Vor jeder Aktion fragen'),
                          subtitle: const Text('Junels zeigt eine Karte mit „Ausführen“'),
                          value: a.confirm,
                          onChanged: (v) {
                            a.confirm = v;
                            save();
                          },
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Auch in Prozessen & geplanten Aufgaben'),
                          subtitle: const Text('Sonst nur, wenn du selbst im Chat oder Gespräch bist'),
                          value: a.inAutomation,
                          onChanged: (v) {
                            a.inAutomation = v;
                            save();
                          },
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
