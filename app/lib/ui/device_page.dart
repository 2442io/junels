// Gerät & Automatik: Heimatort, Schnellstart-Knöpfe,
// überwachte Ordner und (Mac) freigegebene Ordner für die Dateihilfe.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/device_bridge.dart';
import 'quick_nav.dart';

Future<void> openDevicePage(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DevicePage()));

/// Dialog: Morgen-Übersicht einrichten.
Future<void> setupMorningBriefing(BuildContext context) async {
  final app = AppScope.read(context);
  final city = TextEditingController(text: app.settings.homeCity.isEmpty ? 'Wien' : app.settings.homeCity);
  final topics = TextEditingController();
  var time = const TimeOfDay(hour: 7, minute: 0);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        icon: const Icon(Icons.wb_twilight),
        title: const Text('Morgen-Übersicht'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Jeden Morgen eine Push-Nachricht mit deinen Terminen, dem Wetter und den wichtigsten Nachrichten.'),
            const SizedBox(height: 12),
            TextField(controller: city, decoration: const InputDecoration(labelText: 'Ort fürs Wetter')),
            const SizedBox(height: 8),
            TextField(
              controller: topics,
              decoration: const InputDecoration(labelText: 'Nachrichten-Themen (optional)', hintText: 'z. B. KI, Wirtschaft'),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: Text('Uhrzeit: ${time.format(ctx)}'),
              onTap: () async {
                final t = await showTimePicker(context: ctx, initialTime: time);
                if (t != null) set(() => time = t);
              },
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Einrichten')),
        ],
      ),
    ),
  );
  if (ok != true || city.text.trim().isEmpty) return;
  await app.createMorningBriefing(city: city.text.trim(), hour: time.hour, minute: time.minute, topics: topics.text);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Morgen-Übersicht kommt täglich um ${time.format(context)}. Bei der ersten Ausführung fragt das Gerät '
          'einmal nach Zugriff auf den Kalender.'),
      duration: const Duration(seconds: 6),
    ));
  }
}

class DevicePage extends StatefulWidget {
  const DevicePage({super.key});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  Future<void> _checkCalendar(BuildContext context) async {
    final app = AppScope.read(context);
    final now = DateTime.now();
    String text;
    try {
      final cals = await app.deviceBridge.calendarCalendars().timeout(const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('Kalender-Liste antwortet nicht (15 s)'));
      final events = await app.deviceBridge
          .calendarList(DateTime(now.year, now.month, now.day), DateTime(now.year, now.month, now.day + 1))
          .timeout(const Duration(seconds: 15), onTimeout: () => throw TimeoutException('Termine lesen antwortet nicht (15 s)'));
      final b = StringBuffer();
      if (cals.isNotEmpty) {
        b.writeln('Kalender auf dem Gerät:');
        for (final c in cals) {
          b.writeln('• ${c['name']} – ${c['account']} (${c['type']}): ${c['events']} Termine'
              '${c['sync'] == true ? '' : ' · Sync AUS'}${c['visible'] == true ? '' : ' · ausgeblendet'}');
        }
        b.writeln();
      }
      final abos = await DeviceBridge.icsUrls();
      if (abos.isNotEmpty) b.writeln('Kalender-Abos: ${abos.length}\n');
      b.writeln('Heute gefunden: ${events.length}');
      for (final e in events.take(12)) {
        b.writeln('• ${e.allDay ? 'ganztägig' : '${e.begin.hour}:${e.begin.minute.toString().padLeft(2, '0')}'} ${e.title} (${e.calendar})');
      }
      final google = cals.where((c) => '${c['type']}' == 'com.google');
      if (abos.isEmpty && cals.isNotEmpty && (google.isEmpty || google.every((c) => (c['events'] as num? ?? 0) == 0))) {
        b
          ..writeln()
          ..writeln('Kein Google-Kalender mit Terminen sichtbar. Prüfe: Einstellungen → Konten → Google → Kontosynchronisierung → '
              '„Google Kalender“ an, dann in der Google-Kalender-App ⋮ → Aktualisieren. Termine aus einem Arbeitsprofil kann Junels nicht lesen. '
              'Sicherer Weg: oben ein Kalender-Abo mit der iCal-Adresse eintragen.');
      }
      text = b.toString().trim();
    } catch (e) {
      text = 'Kalender nicht lesbar: $e';
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kalender'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  late final _city = TextEditingController(text: AppScope.read(context).settings.homeCity);
  late final _cc = TextEditingController(text: AppScope.read(context).settings.countryCode);

  @override
  void dispose() {
    _city.dispose();
    _cc.dispose();
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final t = Theme.of(context).textTheme;

    Widget card(String title, IconData icon, List<Widget> children) => Card(
          margin: const EdgeInsets.only(bottom: 14),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Icon(icon, size: 20), const SizedBox(width: 8), Text(title, style: t.titleMedium)]),
              const SizedBox(height: 10),
              ...children,
            ]),
          ),
        );

    return Scaffold(
      appBar: JAppBar(title: const Text('Kalender, Gerät & Ordner')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          card('Über dich', Icons.place_outlined, [
            TextField(
              controller: _city,
              decoration: const InputDecoration(labelText: 'Heimatort (für Wetter)', hintText: 'z. B. Wien'),
              onSubmitted: (v) => app.setHomeCity(v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _cc,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Landesvorwahl ohne + (für WhatsApp)', hintText: '43'),
              onSubmitted: (v) => app.setHomeCity(_city.text, countryCode: v),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: () async {
                  await app.setHomeCity(_city.text, countryCode: _cc.text);
                  _snack('Gespeichert');
                },
                child: const Text('Speichern'),
              ),
            ),
          ]),
          card('Kalender', Icons.event_outlined, [
            Text('Junels liest die Kalender dieses Geräts (nur nach Freigabe). Fehlen Termine, zuerst hier prüfen.', style: t.bodySmall),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.search),
              label: const Text('Kalender prüfen'),
              onPressed: () => _checkCalendar(context),
            ),
            const SizedBox(height: 4),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Termine fehlen? Kalender-Abo (iCal) hinzufügen'),
              children: [
                Text('Google: calendar.google.com am Computer → Einstellungen → links deinen Kalender → '
                    '„Privatadresse im iCal-Format“ kopieren und hier einfügen. Junels lädt sie alle 10 Minuten (nur lesen).',
                    style: t.bodySmall),
                const SizedBox(height: 8),
                const _IcsEditor(),
                const SizedBox(height: 8),
              ],
            ),
          ]),
          card('Ordner überwachen', Icons.folder_special_outlined, [
            const Text('Neue PDFs, TXT- und MD-Dateien in diesen Ordnern kommen automatisch in die Wissensbasis '
                '(beim Start und alle 30 Minuten).'),
            for (final f in app.settings.watchFolders)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: Text(f['name'] ?? 'Ordner'),
                trailing: IconButton(
                  tooltip: 'Nicht mehr überwachen',
                  icon: const Icon(Icons.close),
                  onPressed: () => app.removeWatchFolder(f),
                ),
              ),
            const SizedBox(height: 6),
            Row(children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Ordner hinzufügen'),
                onPressed: DeviceBridge.supported ? () => _guard(app.addWatchFolder) : null,
              ),
              const SizedBox(width: 8),
              if (app.settings.watchFolders.isNotEmpty)
                TextButton(onPressed: () => _guard(app.scanWatchFolders), child: const Text('Jetzt prüfen')),
            ]),
          ]),
          if (Platform.isMacOS)
            card('Dateihilfe (Mac)', Icons.drive_file_move_outline, [
              const Text('Der Agent darf in diesen Ordnern Dateien suchen, umbenennen und verschieben – '
                  'jede Änderung bestätigst du vorher. Beispiel: „Sortiere die Rechnungen im Download-Ordner nach Jahr.“'),
              for (final f in app.settings.grantedFolders)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_open_outlined),
                  title: Text(f['name'] ?? ''),
                  subtitle: Text(f['path'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    tooltip: 'Freigabe entfernen',
                    icon: const Icon(Icons.close),
                    onPressed: () => app.removeGrantedFolder(f),
                  ),
                ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Ordner freigeben'),
                onPressed: () => _guard(app.addGrantedFolder),
              ),
            ]),
          if (DeviceBridge.supported)
            card('Schnellstart', Icons.touch_app_outlined, [
              Text(Platform.isAndroid
                  ? 'Lange auf das Junels-Symbol drücken zeigt: Gespräch starten, Neuer Chat und deine ersten 3 Prompts. '
                      'Oder einen Knopf direkt auf den Startbildschirm legen:'
                  : 'Rechtsklick auf das Junels-Symbol im Dock: Gespräch starten, Neuer Chat und deine ersten 3 Prompts. '
                      'PDFs, Bilder und Texte kannst du aufs Dock-Symbol ziehen – sie landen als Anhang im Chat.'),
              if (Platform.isAndroid) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.record_voice_over_outlined),
                    label: const Text('Gespräch-Knopf'),
                    onPressed: () => _pin(app, 'conversation', 'Gespräch'),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add_comment_outlined),
                    label: const Text('Neuer-Chat-Knopf'),
                    onPressed: () => _pin(app, 'newchat', 'Neuer Chat'),
                  ),
                  for (final p in app.prompts.take(5))
                    OutlinedButton.icon(
                      icon: const Icon(Icons.bolt_outlined),
                      label: Text(p.title),
                      onPressed: () => _pin(app, 'prompt:${p.id}', p.title),
                    ),
                ]),
              ],
            ]),
          if (Platform.isAndroid)
            card('Teilen an Junels', Icons.share_outlined, [
              const Text('In jeder App „Teilen“ → Junels: Text und Links landen im Eingabefeld, Fotos und PDFs als Anhang. '
                  'Dann einfach fragen, z. B. „Fass das zusammen“.'),
            ]),
        ],
      ),
    );
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _pin(AppController app, String id, String label) async {
    try {
      final ok = await app.deviceBridge.pinQuickAction(id, label);
      if (!ok) _snack('Dein Startbildschirm unterstützt das Anheften nicht – lange aufs App-Symbol drücken.');
    } catch (e) {
      _snack('$e');
    }
  }
}

/// iCal-Adressen eintragen (liegen im Tresor, weil sie geheim sind).
class _IcsEditor extends StatefulWidget {
  const _IcsEditor();

  @override
  State<_IcsEditor> createState() => _IcsEditorState();
}

class _IcsEditorState extends State<_IcsEditor> {
  List<String> _urls = [];
  final _ctrl = TextEditingController();
  String? _status;

  @override
  void initState() {
    super.initState();
    DeviceBridge.icsUrls().then((u) {
      if (mounted) setState(() => _urls = u);
    });
  }

  String _short(String u) {
    final uri = Uri.tryParse(u);
    return uri == null ? u : '${uri.host}/…${u.length > 12 ? u.substring(u.length - 8) : ''}';
  }

  Future<void> _add() async {
    final u = _ctrl.text.trim();
    if (!RegExp(r'^(https?|webcal)://').hasMatch(u)) {
      setState(() => _status = 'Bitte die vollständige Adresse einfügen (beginnt mit https:// oder webcal://)');
      return;
    }
    _urls = [..._urls, u];
    await DeviceBridge.setIcsUrls(_urls);
    _ctrl.clear();
    await _test();
  }

  Future<void> _test() async {
    setState(() => _status = 'Lade …');
    final app = AppScope.read(context);
    final now = DateTime.now();
    try {
      final ev = await app.deviceBridge.icsEvents(DateTime(now.year, now.month, now.day), DateTime(now.year, now.month, now.day + 7));
      if (mounted) {
        setState(() => _status = ev.isEmpty
            ? 'Keine Termine in den nächsten 7 Tagen gefunden – Adresse prüfen (Protokoll)'
            : '${ev.length} Termine in den nächsten 7 Tagen, z. B. „${ev.first.title}“');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Fehler: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final u in _urls)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.event_note_outlined),
          title: Text(_short(u)),
          trailing: IconButton(
            tooltip: 'Entfernen',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              _urls = [..._urls]..remove(u);
              await DeviceBridge.setIcsUrls(_urls);
              setState(() {});
            },
          ),
        ),
      TextField(
        controller: _ctrl,
        decoration: const InputDecoration(labelText: 'iCal-Adresse einfügen', hintText: 'https://calendar.google.com/calendar/ical/…/basic.ics'),
        onSubmitted: (_) => _add(),
      ),
      const SizedBox(height: 8),
      Row(children: [
        FilledButton.tonal(onPressed: _add, child: const Text('Hinzufügen')),
        const SizedBox(width: 8),
        if (_urls.isNotEmpty) OutlinedButton(onPressed: _test, child: const Text('Testen')),
      ]),
      if (_status != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_status!, style: t.bodySmall)),
    ]);
  }
}
