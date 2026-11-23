// Einstellungen → Benachrichtigungen: Arten an/aus, Ruhezeit, Infos gesammelt.

import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../state/notifications.dart';
import 'notify_style.dart';
import 'theme.dart';
import 'quick_nav.dart';

void openNotifySettings(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotifySettingsPage()));

class NotifySettingsPage extends StatefulWidget {
  const NotifySettingsPage({super.key});

  @override
  State<NotifySettingsPage> createState() => _NotifySettingsPageState();
}

class _NotifySettingsPageState extends State<NotifySettingsPage> {
  late NotifySettings s;

  @override
  void initState() {
    super.initState();
    s = AppScope.read(context).notifySettings;
  }

  Future<void> _save() async {
    setState(() {});
    await AppScope.read(context).saveNotifySettings(s);
  }

  String _hint(NotifyKind k) => switch (k) {
        NotifyKind.aktion => 'Junels wartet auf dich – mit Ton, oben eingeblendet',
        NotifyKind.warnung => 'Fehler und erreichte Grenzwerte – mit Ton',
        NotifyKind.erinnerung => 'Zeitpunkte, die du gesetzt hast – mit Ton, auch in der Ruhezeit',
        NotifyKind.ergebnis => 'Etwas ist fertig – ohne Ton',
        NotifyKind.info => 'Neues ohne Handlungsbedarf – leise',
        NotifyKind.ruhig => '',
      };

  Future<void> _pickHour(bool from) async {
    final r = await showTimePicker(context: context, initialTime: TimeOfDay(hour: from ? s.quietFrom : s.quietTo, minute: 0));
    if (r == null) return;
    if (from) {
      s.quietFrom = r.hour;
    } else {
      s.quietTo = r.hour;
    }
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    return Scaffold(
      appBar: JAppBar(title: const Text('Benachrichtigungen')),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
        Text('Jede Meldung hat eine Art mit eigener Farbe und eigenem Symbol. Ausgeschaltete Arten kommen nicht als Push, '
            'stehen aber weiter unter Mitteilungen (Glocke).',
            style: t.bodySmall?.copyWith(color: c.muted)),
        const SectionLabel('Arten', padding: EdgeInsets.fromLTRB(4, 16, 4, 6)),
        for (final k in NotifyKind.values.where((k) => k != NotifyKind.ruhig))
          SwitchListTile(
            secondary: NotifyBadge(k),
            title: Text(k.label == 'Fertig' ? 'Ergebnis' : k.label),
            subtitle: Text(_hint(k)),
            value: !s.off.contains(k),
            onChanged: (v) {
              if (v) {
                s.off.remove(k);
              } else {
                s.off.add(k);
              }
              _save();
            },
          ),
        const SectionLabel('Ruhezeit', padding: EdgeInsets.fromLTRB(4, 16, 4, 6)),
        SwitchListTile(
          title: const Text('Ruhezeit'),
          subtitle: Text('Warnungen, Ergebnisse und Infos kommen gesammelt am Ende (${s.quietTo}:00). '
              'Aktionen und Erinnerungen kommen durch.'),
          value: s.quiet,
          onChanged: (v) {
            s.quiet = v;
            _save();
          },
        ),
        if (s.quiet)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              OutlinedButton(onPressed: () => _pickHour(true), child: Text('von ${s.quietFrom}:00')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => _pickHour(false), child: Text('bis ${s.quietTo}:00')),
            ]),
          ),
        SwitchListTile(
          title: const Text('Infos einmal täglich gesammelt'),
          subtitle: const Text('Statt einzeln: eine Meldung um 18 Uhr mit allen Infos des Tages'),
          value: s.infoDigest,
          onChanged: (v) {
            s.infoDigest = v;
            _save();
          },
        ),
        const SizedBox(height: 8),
        Text('Ton, Vibration und Sperrbildschirm stellst du je Art in den System-Einstellungen ein (Android: Kanäle „Aktionen“, '
            '„Warnungen“ …). „Nicht stören“ des Systems gilt immer.',
            style: t.bodySmall?.copyWith(color: c.muted)),
      ]),
    );
  }
}
