// Apps öffnen und steuern (z. B. Spotify) – nur Apps aus deiner Freigabeliste.
// Schutz: Junels tippt nie in fremden Apps, gibt nichts ein und kann dort nichts kaufen.
// Erlaubt sind nur: App öffnen, Wiedergabe steuern (Play/Pause/Weiter/Zurück) und – wenn freigegeben –
// eine Suche bzw. einen Link in der App öffnen. Links mit Kauf-/Zahlungs-/Bestell-Bezug werden immer abgelehnt.

import 'package:agent_engine/agent_engine.dart';

/// Eine freigegebene App.
class AllowedApp {
  AllowedApp({required this.name, required this.id, this.links = false, this.confirm = false, this.inAutomation = false});
  String name;
  final String id; // Android: Paketname, Mac: Bundle-ID
  bool links; // Suchen/Links in der App öffnen
  bool confirm; // vor jeder Aktion fragen
  bool inAutomation; // auch in Prozessen/geplanten Aufgaben (ohne dich)

  /// Banking, Bezahlen, Shopping, Lieferdienste: nur öffnen, nie Links.
  bool get sensitive => sensitiveApp('$name $id');

  Map<String, Object> toJson() => {'name': name, 'id': id, 'links': links, 'confirm': confirm, 'auto': inAutomation};
  factory AllowedApp.fromJson(Map<String, dynamic> j) => AllowedApp(
        name: j['name'] as String? ?? '',
        id: j['id'] as String? ?? '',
        links: j['links'] as bool? ?? false,
        confirm: j['confirm'] as bool? ?? false,
        inAutomation: j['auto'] as bool? ?? false,
      );
}

final _sensitive = RegExp(
    r'bank|banking|sparkasse|raiffeisen|erste|bawag|volksbank|n26|revolut|wise|paypal|klarna|wallet|pay\b|\.pay|twint|crypto|coinbase|binance|trade|broker|'
    r'amazon|ebay|shop|store|zalando|temu|shein|aliexpress|wish|willhaben|lieferando|mjam|wolt|foodora|uber|bolt|booking|airbnb|ticket',
    caseSensitive: false);
bool sensitiveApp(String s) => _sensitive.hasMatch(s);

/// Kauf-, Zahlungs- oder Bestellbezug in einer Suche oder einem Link → immer ablehnen.
final _moneyWords = RegExp(
    r'kauf|buy|purchase|checkout|kasse|bezahl|zahl|pay|order|bestell|warenkorb|cart|basket|abo\b|abonn|subscri|premium|upgrade|billing|rechnung|'
    r'donat|spende|gift ?card|gutschein|trinkgeld|tip\b|überweis|transfer|send money|geld senden',
    caseSensitive: false);
bool touchesMoney(String s) => _moneyWords.hasMatch(s);

/// Bekannte Apps: Suche als Link.
String? searchLinkFor(String id, String query, {required bool android}) {
  final q = Uri.encodeComponent(query.trim());
  if (q.isEmpty) return null;
  final l = id.toLowerCase();
  if (l.contains('spotify')) return 'spotify:search:$q';
  if (l.contains('youtube.music') || l.contains('youtubemusic')) return 'https://music.youtube.com/search?q=$q';
  if (l.contains('youtube')) return 'https://www.youtube.com/results?search_query=$q';
  if (l.contains('com.apple.music') || l == 'com.apple.music') return 'music://music.apple.com/search?term=$q';
  if (l.contains('maps')) return android ? 'geo:0,0?q=$q' : 'maps://?q=$q';
  if (l.contains('podcast')) return android ? 'https://podcasts.google.com/search/$q' : 'podcasts://search?term=$q';
  return null;
}

class AppControlTool extends AgentTool {
  AppControlTool({
    required this.allowed,
    required this.launch,
    required this.mediaKey,
    required this.openInApp,
    required this.unattended,
    required this.android,
  });
  final List<AllowedApp> Function() allowed;
  final Future<void> Function(String id) launch;
  final Future<void> Function(String id, String key) mediaKey;
  final Future<void> Function(String id, String url) openInApp;
  final bool Function() unattended;
  final bool android;

  @override
  String get name => 'control_app';
  @override
  String get title => 'Apps öffnen & steuern';
  @override
  String get keywords => 'app öffnen starte spotify musik abspielen pause weiter nächster titel zurück lied playlist podcast youtube';
  @override
  String get description {
    final names = allowed().map((a) => a.name).join(', ');
    return 'Öffnet freigegebene Apps und steuert die Wiedergabe. Freigegeben: ${names.isEmpty ? '(keine)' : names}. '
        'aktion: oeffnen, abspielen_pause, abspielen, pause, weiter, zurueck, suchen (nur wenn für die App erlaubt; suche = Text). '
        '„Such nach Jazz“ ohne App-Namen = suchen in der freigegebenen Musik-App (app leer lassen). '
        'Kann nichts tippen, kaufen, bestellen oder bezahlen.';
  }

  @override
  List<ToolParam> get params => const [
        ToolParam('app', ParamType.string, 'Name der App, z. B. Spotify'),
        ToolParam('aktion', ParamType.enumeration, 'Was tun',
            values: ['oeffnen', 'abspielen_pause', 'abspielen', 'pause', 'weiter', 'zurueck', 'suchen']),
        ToolParam('suche', ParamType.string, 'Suchtext für "suchen" (sonst "")'),
      ];

  AllowedApp? find(String name) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    final list = allowed();
    return list.where((a) => a.name.toLowerCase() == n || a.id.toLowerCase() == n).firstOrNull ??
        list.where((a) => a.name.toLowerCase().contains(n) || n.contains(a.name.toLowerCase()) || a.id.toLowerCase().contains(n)).firstOrNull;
  }

  /// Prüft eine Aktion. Ergebnis: (App, Link oder null) oder Ausnahme mit verständlichem Grund.
  /// Ohne (passenden) App-Namen: die App, in der gesucht werden darf – Musik-Apps zuerst.
  AllowedApp? defaultSearchApp() {
    final ok = allowed().where((a) => a.links && !a.sensitive && searchLinkFor(a.id, 'x', android: android) != null).toList();
    return ok.where((a) => RegExp(r'spotify|music|musik|deezer|tidal', caseSensitive: false).hasMatch('${a.id} ${a.name}')).firstOrNull ??
        ok.firstOrNull;
  }

  (AllowedApp, String?) check(String appName, String action, String query) {
    var app = find(appName);
    if (app == null && action == 'suchen') app = defaultSearchApp();
    if (app == null) {
      throw ToolException('„$appName“ ist nicht freigegeben. Hinweis für den Nutzer: Einstellungen → Apps steuern → App hinzufügen.');
    }
    if (unattended() && !app.inAutomation) {
      throw ToolException('„${app.name}“ darf nur gesteuert werden, wenn du selbst dabei bist (nicht in Prozessen/geplanten Aufgaben).');
    }
    if (action == 'suchen') {
      if (app.sensitive) throw ToolException('Bei „${app.name}“ (Bank/Shop/Zahlung) öffnet Junels nur die App – keine Suchen oder Links.');
      if (!app.links) throw ToolException('Suchen in „${app.name}“ ist nicht freigegeben – nur öffnen und Wiedergabe steuern.');
      if (touchesMoney(query)) throw ToolException('Abgelehnt: Kaufen, Bestellen, Abos oder Zahlungen macht Junels nie.');
      final link = searchLinkFor(app.id, query, android: android);
      if (link == null) throw ToolException('Für „${app.name}“ kennt Junels keine Suche – nur öffnen und Wiedergabe steuern.');
      return (app, link);
    }
    return (app, null);
  }

  /// Führt eine (geprüfte) Aktion aus.
  Future<String> execute(AllowedApp app, String action, String? link) async {
    switch (action) {
      case 'oeffnen':
        await launch(app.id);
        return '„${app.name}“ geöffnet.';
      case 'suchen':
        await openInApp(app.id, link!);
        return 'Suche in „${app.name}“ geöffnet. Abspielen musst du dort selbst antippen (oder sag „abspielen“).';
      default:
        final key = switch (action) {
          'abspielen' => 'play',
          'pause' => 'pause',
          'weiter' => 'next',
          'zurueck' => 'previous',
          _ => 'playpause',
        };
        await mediaKey(app.id, key);
        return switch (key) {
          'play' => 'Wiedergabe gestartet.',
          'pause' => 'Pausiert.',
          'next' => 'Nächster Titel.',
          'previous' => 'Vorheriger Titel.',
          _ => 'Wiedergabe umgeschaltet.',
        };
    }
  }

  @override
  Future<String> run(Map<String, dynamic> args, ToolContext ctx) async {
    final action = (args['aktion'] ?? 'oeffnen').toString();
    final query = (args['suche'] ?? '').toString();
    final (app, link) = check((args['app'] ?? '').toString(), action, query);
    if (app.confirm && ctx.propose != null) {
      ctx.propose!({
        'type': 'app',
        'app': app.name,
        'id': app.id,
        'action': action,
        if (link != null) 'url': link,
        'body': '${_label(action)}${query.isEmpty ? '' : ': „$query“'}',
        'status': 'pending',
      });
      ctx.answerNow = true;
      return 'Vorschlag erstellt – der Nutzer bestätigt mit „Ausführen“.';
    }
    ctx.answerNow = true;
    return execute(app, action, link);
  }

  static String _label(String a) => switch (a) {
        'oeffnen' => 'Öffnen',
        'abspielen_pause' => 'Abspielen/Pause',
        'abspielen' => 'Abspielen',
        'pause' => 'Pause',
        'weiter' => 'Nächster Titel',
        'zurueck' => 'Vorheriger Titel',
        'suchen' => 'Suchen',
        _ => a,
      };
}
