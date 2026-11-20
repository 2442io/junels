// Gerät & Automatik: Heimatort, Morgen-Übersicht, Schnellstart-Knöpfe,
// überwachte Ordner und (Mac) freigegebene Ordner für die Dateihilfe.

import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/app_scope.dart';
import '../state/device_bridge.dart';

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
    final hasBriefing = app.prompts.any((p) => p.title == 'Morgen-Übersicht');

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
      appBar: AppBar(title: const Text('Gerät & Automatik')),
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
          card('Morgen-Übersicht', Icons.wb_twilight, [
            Text(hasBriefing
                ? 'Eingerichtet – unter „Meine Prompts“ änderst du Uhrzeit und Inhalt.'
                : 'Jeden Morgen Termine, Wetter und Nachrichten als Push-Nachricht.'),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.wb_twilight),
              label: Text(hasBriefing ? 'Neu einrichten' : 'Einrichten'),
              onPressed: () => setupMorningBriefing(context),
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
          card('Was der Agent jetzt kann', Icons.info_outline, [
            const Text('• „Schreib Anna eine Mail, dass …“ → Mail-App mit Entwurf\n'
                '• „Schick Max auf WhatsApp, dass ich später komme“ → WhatsApp mit Text\n'
                '• „Ruf Mama an“ → Telefon-App mit Nummer\n'
                '• „Was habe ich heute für Termine?“ / „Trag morgen 9:30 Zahnarzt ein“\n'
                '• „Wie wird das Wetter?“ / „Was gibt’s Neues zu KI?“\n'
                'Senden, Anrufen und Speichern bestätigst immer du in der jeweiligen App.'),
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

/// Für Listen: Hinweis-Kachel unter „Meine Prompts“.
Widget morningBriefingTile(BuildContext context, AppController app) {
  if (app.prompts.any((p) => p.title == 'Morgen-Übersicht')) return const SizedBox.shrink();
  return ListTile(
    dense: true,
    contentPadding: const EdgeInsets.only(left: 4),
    leading: const Icon(Icons.wb_twilight, size: 20),
    title: const Text('Morgen-Übersicht einrichten'),
    subtitle: const Text('Termine, Wetter, News als Push'),
    onTap: () => setupMorningBriefing(context),
  );
}
