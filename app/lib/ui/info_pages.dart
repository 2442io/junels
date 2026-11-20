// Versionsverlauf und App-Protokoll.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/native_files.dart';
import '../state/voice_service.dart';
import '../version.dart';

const changelog = <(String, List<String>)>[
  ('1.20.2', [
    'Browser war nach dem Update bei bestehenden Installationen ausgeschaltet – jetzt aktiv',
    '„Suche auf amazon.de nach …“ öffnet direkt die Suche der Seite im Browser, ohne Umweg über das Modell',
    '„Weitere Ergebnisse dazu“ und ähnliche Nachfragen beziehen sich wieder auf die vorige Suche',
    'Links im Text: kurz und lesbar („amazon.de – Suche: brotdosen“) statt langer Adressen',
    'Neue Stimmen: Kokoro Victoria (weiblich, ca. 100 MB), Piper Thorsten HD, Eva, Ramona, Karlsson, Pavoque',
  ]),
  ('1.20.1', [
    'Neue Stimme: Kokoro Deutsch – Martin (sehr natürlich, ca. 316 MB) – im Systemcheck unter Stimmen laden und auswählen',
  ]),
  ('1.20.0', [
    'Gespräch: Name für den Agenten frei wählbar (Einstellungen im Gespräch); „Nur auf den Namen hören“ – Geräusche lösen nichts mehr aus',
    'Kurz nach einer Antwort geht eine Nachfrage auch ohne Namen; unterbrechen mit dem Namen oder Tipp auf den Kreis',
    'Gespräch bricht nicht mehr ab: das Mikrofon wird nicht mehr neu gestartet, während der Agent spricht',
    'Der Agent wiederholt deine Frage nicht mehr, sondern antwortet sofort',
    'Schneller: Wetter- und Nachrichtenfragen laufen ohne Planungsschritt; nach Shop-/Browser-Suche antwortet der Agent direkt',
    'Wetter: immer 7-Tage-Vorhersage mit Datum – „Wetter am Dienstag“ funktioniert',
    'Nachrichten: echte Sport-, Wirtschafts-, Wissenschafts- und Kultur-Feeds (z. B. ORF Sport)',
    'Neue Fragen nach einem Kalendereintrag benutzen nicht mehr fälschlich den Kalender',
  ]),
  ('1.19.1', [
    'Gespräch: hängt nach der ersten Antwort nicht mehr – das Mikrofon wird automatisch neu gestartet, wenn es nach dem Vorlesen verstummt',
    'Gespräch: der Kreis pulsiert, während der Agent spricht oder denkt; Tippen auf den Kreis = „Fertig – antworten“ bzw. Unterbrechen',
    'Spracherkennung wiederholt Sätze nicht mehr endlos',
    'Browser: nur noch eine farbige Leiste über dem Chat – Seite bei Bedarf aufklappen, Leiste schließen; gilt nur für den Chat, in dem er benutzt wurde',
    'Browser funktioniert schon beim ersten Mal (Seite wird im Hintergrund richtig aufgebaut)',
    'Karussell erscheint zuverlässig, auch bei langen Ergebnissen; Produktbilder von Amazon werden geladen',
    'Keine langen Adressen mehr im Text: Links als Karten bzw. kurz „amazon.de › Produkt“, Werbe-Weiterleitungen werden aufgelöst',
    'Nach 30 Minuten ohne Nutzung startet die App mit einem neuen Chat',
  ]),
  ('1.19.0', [
    'Eingebauter Browser: Der Agent öffnet Seiten, sucht über deren Suchfeld, klickt, tippt und scrollt – du schaust live zu',
    'Treffer aus dem Browser (z. B. Amazon-Produkte mit Bild und Preis) erscheinen im Karussell',
    'Captcha oder Anmeldung: Du übernimmst kurz selbst und tippst auf „Weiter“',
    'Sicherheit: Vor Kaufen, Bestellen, Absenden oder Löschen fragt der Agent nach; Passwörter und Zahlungsdaten gibst nur du ein',
    'Knopf oben zum Ein- und Ausblenden des Browsers; auf dem Mac rechts neben dem Chat, am Handy darüber',
  ]),
  ('1.18.1', [
    'Shop-Suche: keine App-Store-, Google-Play- oder Menü-Links mehr im Karussell – nur Treffer, die zur Frage passen',
    'Ist Amazon gesperrt, sucht Junels zuerst über eine Suchmaschine nach Amazon-Links, erst danach auf Geizhals/Idealo',
  ]),
  ('1.18.0', [
    'Alle Web-Inhalte als Karussell: Websuche, Webseiten, Shop-Suche und Nachrichten – mit Bild, Titel, Text und Link',
    '„Weitere laden“ am Ende des Karussells (bis zu 60 Treffer) und „Mehr suchen“ für eine neue Suche',
    'Das Sprachmodell bekommt nur die besten Treffer – schneller, der Rest steht in den Karten',
    'Updates funktionieren ohne GitHub-Token, wenn das Repository öffentlich ist',
  ]),
  ('1.17.0', [
    'MCP-Store: empfohlene Server von GitHub, Notion, Atlassian, Microsoft, Stripe … und Suche im offiziellen MCP Registry – mit einem Tipp hinzufügen',
    'Anmeldung im Browser (OAuth) für MCP-Server, Token werden automatisch erneuert',
    'Suchergebnisse (Produkte, Nachrichten) als wischbares Karussell mit Bild, Titel, Preis und Link',
  ]),
  ('1.16.0', [
    'Neu: Suche direkt auf Webseiten (Amazon, Geizhals, Idealo, eBay, willhaben, Wikipedia … oder über das Suchfeld jeder Seite) – mit Preis, Bild und Link',
    'Blockiert ein Shop (z. B. Amazon mit Captcha), sucht der Agent automatisch bei Geizhals/Idealo weiter',
    'Websuche robuster: DuckDuckGo, DuckDuckGo Lite, Bing und Mojeek; Seiten werden wie mit einem Handy-Browser abgerufen',
    'Der Agent nennt den konkreten Grund, wenn etwas nicht klappt, statt „kein Zugriff“',
    'Einkaufs- und Suchanfragen („such mir Angebote …“) bekommen jetzt zuverlässig die Websuche',
  ]),
  ('1.15.1', [
    'Gespräch: Spracherkennung rechnet nur noch die tatsächliche Aufnahmelänge statt immer 30 s (bei kurzen Sätzen 3–5× schneller)',
    'Am Handy wird für Gespräche Whisper small empfohlen (turbo ist auf dem Handy-Prozessor zu langsam)',
    'Erste Worte früher: Vorlesen startet schon am ersten Komma eines langen Satzes',
    'Gesprächsverlauf so gekürzt, dass der vorgerechnete Teil von Runde zu Runde erhalten bleibt',
    'Tipps in der Zeitanzeige, wenn Spracherkennung oder Antwort zu langsam sind',
  ]),
  ('1.15.0', [
    'Menü neu geordnet: oben Modell-Status mit „Neuer Chat“ und „Gespräch“',
    'Täglich gebraucht zuerst: Chats (die letzten 8, ältere aufklappbar) und Meine Prompts',
    'Einrichten in aufklappbaren Gruppen: Modell · Agent & Werkzeuge · Sprache · Gerät & Verbindungen · App',
    'Jede Gruppe zeigt zugeklappt eine Kurzinfo (z. B. geladenes Modell, aktive Werkzeuge)',
  ]),
  ('1.14.0', [
    'E-Mail und WhatsApp vorbereiten, Anrufen – mit Empfängern aus dem Adressbuch; du sendest bzw. rufst selbst',
    'Kalender: Termine abfragen und eintragen',
    'Wetter (Open-Meteo) und Nachrichten (ORF, Der Standard, tagesschau, futurezone, heise, Golem) als feste Werkzeuge',
    'Morgen-Übersicht: Termine, Wetter und News jeden Morgen als Push-Nachricht',
    'Teilen an Junels aus jeder App (Android) bzw. Dateien aufs Dock-Symbol ziehen (Mac)',
    'Schnellstart: Knöpfe auf dem Startbildschirm, App-Verknüpfungen bzw. Dock-Menü',
    'Fotos aufnehmen und auswerten: zusammenfassen, abschreiben, Termin anlegen, Kassenbon',
    'Ordner überwachen: neue PDFs automatisch in die Wissensbasis',
    'Mac: Dateien in freigegebenen Ordnern suchen, umbenennen und verschieben – jeweils mit Rückfrage',
  ]),
  ('1.13.1', [
    'Kein „<channel|>“ und kein Gedankentext mehr in Antworten (Gemma 4 denkt nicht mehr laut nach – auch schneller)',
    'Internet-Freigabe: Knöpfe nebeneinander („Nein / Einmal / Ganzer Chat“)',
    'Kurze Nachfragen wie „wien“ nach einer Wetterfrage bekommen wieder die Websuche',
  ]),
  ('1.13.0', [
    'Werkzeuge nur noch, wenn die Nachricht sie braucht – „Hi“ oder normale Fragen werden direkt beantwortet (viel schneller, keine unnötige Websuche)',
    'Rechenfragen („15 % von 2.340 €“) werden sofort exakt berechnet',
    'Rechner versteht Prozent, Euro-Beträge und Tausenderpunkte',
  ]),
  ('1.12.0', [
    'Dauer jeder Antwort wird angezeigt (Sekunden/Minuten)',
    'Unter der letzten Antwort: was der Agent gerade tut und seit wann (Laden, Lesen, Werkzeug, Schreiben)',
    'Updates direkt in der App: Hinweis im Menü, Download und Installation mit einem Tipp',
  ]),
  ('1.11.0', [
    'Abgleich zwischen Mac und Android: über den eigenen Server oder direkt im WLAN, Ende-zu-Ende verschlüsselt',
    'Protokoll: Fehler, Ladezeiten und Antwortzeiten einsehen, kopieren und teilen',
    'Versionsverlauf in der App',
    'Internet pro Chat: aus / jedes Mal fragen / erlaubt – auch im Gesprächsmodus (mit Nachfrage)',
    'Fokus-Modus: nur der Chat, alle Leisten zu',
    'Deutlich schnellere Folgeantworten bei Qwen 3.5 (Zwischenstände statt Neuberechnung) und Gemma (voller Cache)',
  ]),
  ('1.10.0', [
    'Versionsnummer im Menü',
    'Quellen aus der Wissensbasis nur noch bei echten Treffern',
    'Gesprächsmodus antwortet direkt (ohne Agenten-Schleife) und ist vorgewärmt',
    'Kein Abbruch mehr bei Speicherwarnungen von Android',
    'Absender-Modus nimmt alles auf; Anzeige von Erkennungs- und Antwortzeiten',
  ]),
  ('1.9.0', [
    'Links klickbar – mit Hinweis beim Verlassen der App',
    'Bilder aus Webseiten direkt in der Antwort',
    'Denkschritte immer eingeklappt',
    'KI-Spracherkennung (Silero), „Nur meine Stimme“, einstellbare Sprechpause',
    'Absender-Modus mit „Fertig – antworten“',
  ]),
  ('1.8.0', [
    'Prompts per Chat anlegen („Speichere als Prompt …“)',
    'Gewählte Kontextgröße bleibt erhalten',
    'Webseiten: News-Einträge mit Titel, Bild und Link; RSS-Feeds',
  ]),
  ('1.7.0', [
    'Push-Nachrichten und Erinnerungen',
    'Gesendete Nachrichten bearbeiten, wiederholen, neu erzeugen',
    'Schneller bereit nach dem Laden (vorberechneter System-Prompt)',
    'MCP-Server anbinden',
  ]),
  ('1.0 – 1.6', [
    'Meine Prompts mit Zeitplan (z. B. jeden Morgen 08:30)',
    'Stabile Signatur: Modelle bleiben bei Updates erhalten',
    'PDFs und Bilder hochladen, Bildverständnis',
    'PDFs, Präsentationen, Diagramme und Bilder erzeugen',
    'Arbeit im Hintergrund auf Android',
    'Quellen bei jeder Antwort',
    'Lokale Modelle passend zum Gerät, Downloads in der App, Whisper und Piper, Gedächtnis, Wissensbasis',
  ]),
];

Future<void> openChangelog(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Versionsverlauf')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Installiert: Junels $appVersion (Build $appBuild)', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            for (final (v, items) in changelog)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('Version $v', style: Theme.of(context).textTheme.titleMedium),
                      if (v == appVersion) ...[
                        const SizedBox(width: 8),
                        const Chip(label: Text('installiert'), visualDensity: VisualDensity.compact),
                      ],
                    ]),
                    const SizedBox(height: 6),
                    for (final i in items)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('•  '),
                          Expanded(child: Text(i)),
                        ]),
                      ),
                  ]),
                ),
              ),
          ],
        ),
      ),
    ));

Future<void> openLog(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LogPage()));

class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  bool _errorsOnly = false;

  List<String> _lines() {
    final f = voiceLogFile;
    if (f == null || !f.existsSync()) return const [];
    try {
      final all = f.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList().reversed;
      return [for (final l in all) if (!_errorsOnly || l.contains('FEHLER')) l].take(800).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Protokoll'),
        actions: [
          IconButton(
            tooltip: 'Kopieren',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _lines().reversed.join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Protokoll kopiert')));
            },
          ),
          IconButton(
            tooltip: 'Teilen',
            icon: Icon(Platform.isMacOS ? Icons.ios_share : Icons.share),
            onPressed: () {
              final f = voiceLogFile;
              if (f != null && f.existsSync()) NativeFiles.share(f.path);
            },
          ),
          IconButton(
            tooltip: 'Leeren',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              try {
                voiceLogFile?.writeAsStringSync('');
              } catch (_) {}
              setState(() {});
            },
          ),
        ],
      ),
      body: Column(children: [
        SwitchListTile(
          title: const Text('Nur Fehler'),
          value: _errorsOnly,
          onChanged: (v) => setState(() => _errorsOnly = v),
        ),
        const Divider(height: 1),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: logTick,
            builder: (context, _, __) {
              final lines = _lines();
              if (lines.isEmpty) return const Center(child: Text('Noch keine Einträge.'));
              return ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: lines.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, i) {
                  final l = lines[i];
                  final err = l.contains('FEHLER');
                  return SelectableText(
                    l,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: const ['Menlo', 'Courier'],
                      fontSize: 12,
                      color: err ? scheme.error : scheme.onSurface,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ]),
    );
  }
}
