// Verbindung zu den Gerätefunktionen (Android/macOS) über den Kanal "junels/device".

import 'dart:async';
import 'dart:io';

import 'package:agent_engine/agent_engine.dart';
import 'package:flutter/services.dart';

import 'voice_service.dart' show appLog;

class SharedContent {
  SharedContent(this.text, this.files, {this.send = false});
  final String text;
  final List<(String path, String name)> files;

  /// Gleich als Frage abschicken (Kurzbefehl „junels://frage?text=…“).
  final bool send;
}

class DeviceBridge implements DeviceActions {
  DeviceBridge({required this.countryCodeOf});
  static const _ch = MethodChannel('junels/device');
  final String Function() countryCodeOf;

  /// Rückfrage-Dialog (von der Oberfläche gesetzt).
  Future<bool> Function(String title, String detail)? confirmHandler;

  void Function(String action)? onLaunchAction;
  void Function(SharedContent content)? onShared;

  /// junels://…-Link, der nicht für den Chat gedacht ist (z. B. junels://sso/<code> nach der SSO-Anmeldung).
  void Function(Uri link)? onLink;

  /// Netzwerkstatus des Systems hat sich geändert.
  void Function(bool online)? onNetwork;

  /// Installierte Apps (Name, ID) – für die Freigabeliste.
  Future<List<(String, String)>> listApps() async {
    if (!supported) return const [];
    final r = await _ch.invokeListMethod<Map>('listApps') ?? const [];
    return [for (final m in r) ('${m['name']}', '${m['id']}')];
  }

  Future<void> launchApp(String id) => _ch.invokeMethod('launchApp', {'id': id});
  Future<void> mediaKey(String id, String key) => _ch.invokeMethod('mediaKey', {'id': id, 'key': key});
  Future<void> openInApp(String id, String url) => _ch.invokeMethod('openInApp', {'id': id, 'url': url});
  Future<void> playSearch(String id, String query, String? uri) =>
      _ch.invokeMethod('playSearch', {'id': id, 'query': query, if (uri != null) 'uri': uri});

  /// Ist das Gerät laut System online? null = unbekannt (z. B. iPad/Tests).
  Future<bool?> networkStatus() async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<bool>('networkStatus');
    } catch (_) {
      return null;
    }
  }

  static bool get supported => Platform.isAndroid || Platform.isMacOS;

  void init() {
    if (!supported) return;
    _ch.setMethodCallHandler((call) async {
      final a = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
      switch (call.method) {
        case 'launchAction':
          final id = a['id'] as String?;
          if (id != null) onLaunchAction?.call(id);
        case 'shared':
          final c = _parseShared(a);
          if (c != null) onShared?.call(c);
        case 'network':
          onNetwork?.call(a['online'] != false);
        case 'link':
          final u = Uri.tryParse('${a['url'] ?? ''}');
          if (u != null) onLink?.call(u);
      }
      return null;
    });
  }

  /// Start über Schnellstart-Knopf oder „Teilen an Junels“?
  Future<(String?, SharedContent?)> takeLaunch() async {
    if (!supported) return (null, null);
    try {
      final r = (await _ch.invokeMethod<Map>('takeLaunch'))?.cast<String, dynamic>() ?? const {};
      final shared = r['shared'] is Map ? _parseShared((r['shared'] as Map).cast<String, dynamic>()) : null;
      final link = Uri.tryParse('${r['link'] ?? ''}');
      if (link != null && link.scheme == 'junels') onLink?.call(link);
      return (r['action'] as String?, shared);
    } catch (e) {
      return (null, null);
    }
  }

  SharedContent? _parseShared(Map<String, dynamic> a) {
    final files = [
      for (final f in (a['files'] as List? ?? const []))
        ((f as Map)['path'] as String, (f['name'] as String?) ?? (f['path'] as String).split('/').last),
    ];
    final text = (a['text'] as String? ?? '').trim();
    if (text.isEmpty && files.isEmpty) return null;
    return SharedContent(text, files, send: a['send'] == true);
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (!supported) throw ToolException('Auf diesem Gerät nicht verfügbar.');
    try {
      return await _ch.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      appLog('Gerät', '$method: ${e.message}', error: true);
      throw ToolException(e.message ?? e.code);
    } on MissingPluginException {
      throw ToolException('Auf diesem Gerät nicht verfügbar.');
    }
  }

  @override
  String get countryCode => countryCodeOf();

  @override
  Future<List<ContactInfo>> contacts(String query) async {
    final r = await _call<List>('contacts', {'query': query}) ?? const [];
    return [
      for (final m in r.cast<Map>())
        ContactInfo(m['name'] as String? ?? '', (m['phones'] as List? ?? const []).cast<String>(),
            (m['emails'] as List? ?? const []).cast<String>()),
    ];
  }

  @override
  Future<void> composeEmail(String to, String subject, String body) =>
      _call('composeEmail', {'to': to, 'subject': subject, 'body': body});

  @override
  Future<void> whatsapp(String phone, String text) => _call('whatsapp', {'phone': phone, 'text': text});

  @override
  Future<void> dial(String number) => _call('dial', {'number': number});

  @override
  Future<void> calendarInsert(CalendarEvent e) => _call('calendarInsert', {
        'title': e.title,
        'begin': e.begin.millisecondsSinceEpoch,
        'end': e.end.millisecondsSinceEpoch,
        'allDay': e.allDay,
        'location': e.location,
        'notes': e.notes,
      });

  @override
  Future<List<CalendarEvent>> calendarList(DateTime from, DateTime to) async {
    final r = await _call<List>('calendarList', {'from': from.millisecondsSinceEpoch, 'to': to.millisecondsSinceEpoch}) ?? const [];
    return [
      for (final m in r.cast<Map>())
        CalendarEvent(
          m['title'] as String? ?? '',
          DateTime.fromMillisecondsSinceEpoch((m['begin'] as num).toInt()),
          DateTime.fromMillisecondsSinceEpoch((m['end'] as num).toInt()),
          allDay: m['allDay'] == true,
          location: m['location'] as String? ?? '',
          notes: m['notes'] as String? ?? '',
          calendar: m['calendar'] as String? ?? '',
        ),
    ];
  }

  @override
  Future<String> calendarInfo() async {
    if (!Platform.isAndroid) return '';
    final r = await _call<List>('calendarInfo') ?? const [];
    final cals = r.cast<Map>();
    appLog('Gerät', 'Kalender: ${cals.map((c) => '${c['name']} (${c['account']}, ${c['events']} Termine, sichtbar ${c['visible']}, Sync ${c['sync']})').join('; ')}');
    if (cals.isEmpty) {
      return 'HINWEIS: Junels sieht auf diesem Gerät keinen einzigen Kalender. Sag dem Nutzer: In Android Einstellungen → Konten → '
          'Google → Kontosynchronisierung „Kalender“ einschalten (Termine aus einem Arbeitsprofil kann Junels nicht lesen).';
    }
    final total = cals.fold<int>(0, (a, c) => a + ((c['events'] as num?)?.toInt() ?? 0));
    final names = cals.map((c) => '${c['name']} (${c['account']}: ${c['events']} Termine${c['sync'] == true ? '' : ', Sync aus'})').join(', ');
    // Typisch: nur Geburtstage/Feiertage da, das Google-Konto liefert keine eigenen Termine
    final google = cals.where((c) => '${c['type']}' == 'com.google' && !'${c['name']}'.toLowerCase().contains(RegExp(r'geburtstag|birthday|feiertag|holiday|kontakte|contacts')));
    final googleEmpty = google.isNotEmpty && google.every((c) => ((c['events'] as num?)?.toInt() ?? 0) == 0);
    final syncOff = cals.any((c) => c['sync'] != true);
    if (total > 0 && !googleEmpty && !syncOff) return ''; // alles in Ordnung – kein Hinweis
    return 'Gelesene Kalender: $names. HINWEIS FÜR DEN NUTZER: '
        '${total == 0 ? 'In keinem Kalender liegen Termine auf dem Gerät' : googleEmpty ? 'Die Google-Kalender auf dem Gerät sind leer (nur Geburtstage/Feiertage sichtbar)' : 'Bei einigen Kalendern ist die Synchronisierung aus'} – '
        'vermutlich ist die Kalender-Synchronisierung aus (Android Einstellungen → Konten → Google → Kontosynchronisierung → Kalender) '
        'oder die Termine liegen in einem Arbeitsprofil. Sag das dem Nutzer kurz, damit er weiß, warum Termine fehlen können.';
  }

  @override
  Future<List<FileHit>> fileSearch(String query, String ext) async {
    final r = await _call<List>('fileSearch', {'query': query, 'ext': ext}) ?? const [];
    return [
      for (final m in r.cast<Map>())
        FileHit(m['path'] as String, m['name'] as String,
            isDir: m['dir'] == true,
            size: (m['size'] as num?)?.toInt() ?? 0,
            modified: m['modified'] == null ? null : DateTime.fromMillisecondsSinceEpoch((m['modified'] as num).toInt())),
    ];
  }

  @override
  Future<String> fileRename(String path, String newName) async =>
      await _call<String>('fileRename', {'path': path, 'name': newName}) ?? newName;

  @override
  Future<String> fileMove(String path, String folder) async =>
      await _call<String>('fileMove', {'path': path, 'folder': folder}) ?? folder;

  @override
  Future<bool> confirm(String title, String detail) async {
    final h = confirmHandler;
    if (h == null) return false;
    return h(title, detail);
  }

  // ------------------------------------------------------------- Weiteres

  /// Foto mit der Kamera aufnehmen (Android); liefert den Pfad.
  Future<String?> takePhoto() => _call<String>('takePhoto');

  /// Ordner auswählen (Android: Ordnerzugriff, Mac: Freigabe). {id, name, path?}
  Future<Map<String, String>?> pickFolder({String message = ''}) async {
    final r = await _call<Map>('pickFolder', {'message': message});
    return r?.map((k, v) => MapEntry(k as String, v.toString()));
  }

  /// Mac: gespeicherte Ordnerfreigaben wieder öffnen.
  Future<void> grantFolders(List<String> ids) async {
    if (!Platform.isMacOS || ids.isEmpty) return;
    try {
      await _call('grantFolders', {'ids': ids});
    } catch (_) {}
  }

  /// Neue/geänderte Dateien (PDF, TXT, MD) seit [since] – als lokale Kopien bzw. Pfade.
  Future<List<(String path, String name, int modified)>> scanFolder(String id, int since) async {
    final r = await _call<List>('scanFolder', {'id': id, 'since': since}) ?? const [];
    return [
      for (final m in r.cast<Map>()) (m['path'] as String, m['name'] as String, (m['modified'] as num).toInt()),
    ];
  }

  /// Schnellstart: Android-App-Verknüpfungen bzw. Mac-Dock-Menü.
  Future<void> setQuickActions(List<(String id, String label)> items) async {
    if (!supported) return;
    try {
      await _call('setQuickActions', {
        'items': [for (final (id, label) in items) {'id': id, 'label': label}],
      });
    } catch (_) {}
  }

  /// Android: Knopf auf den Startbildschirm legen.
  Future<bool> pinQuickAction(String id, String label) async =>
      await _call<bool>('pinQuickAction', {'id': id, 'label': label}) ?? false;
}
