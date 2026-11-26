// Versionsverlauf und App-Protokoll.

import 'dart:io';

import 'package:flutter/material.dart';

import 'theme.dart';
import 'update_page.dart';
import 'package:flutter/services.dart';

import '../state/native_files.dart';
import '../state/voice_service.dart';
import '../version.dart';
import 'quick_nav.dart';

const changelog = <(String, List<String>)>[
  ('1.65.0', [
    'Geplante Aufgaben sind jetzt Skills mit Zeitplan – alles unter „Skills & Abläufe“, bestehende Aufgaben werden automatisch übernommen',
    'Skills & Abläufe neu gestaltet: Tabs Alle · Geplant · Skills · Abläufe · Beobachtet, klare Karten mit nächstem/letztem Lauf, Format und Status, ▶ und An/Aus direkt an der Karte',
    '„Neu“ fragt zuerst, was du anlegen willst (geplante Aufgabe, Skill, Ablauf, Beobachtung); ohne Einträge gibt es einen Einstieg „Womit fangen wir an?“',
    'Editor aufgeräumt: Was soll Junels tun? → Wann (Täglich / Mo–Fr / Wöchentlich, Uhrzeit, Push) → Darstellung; Befehl, Werkzeuge, Modell und Ablauf unter „Erweitert“',
    'Darstellung auch für geplante Aufgaben wählbar (Karten, Tabelle, Checkliste, Word, Excel …)',
    'Skills ohne gewählte Werkzeuge nutzen automatisch die passenden – wie im Chat',
    'Ergebnisse geplanter Aufgaben erscheinen zuverlässig in „Ergebnisse“ (auch Läufe im Android-Hintergrund und „Termine vorbereiten“)',
  ]),
  ('1.64.0', [
    'Schnellmenü: neben „Zum Chat“ und „Neuer Chat“ jetzt auch „Voice“',
    'Gespräch (Mac): kein stummes „Ich spreche …“ mehr – die Echo-Unterdrückung des Mikrofons hat die eigene Stimme fast lautlos gedreht; am Mac jetzt aus (Schwelle beim Sprechen höher)',
    'Sprachausgabe prüft, ob wirklich etwas abgespielt wird – sonst wird der Player neu gestartet bzw. die Systemstimme genutzt',
    'Erstes Wort wird nicht mehr abgeschnitten: 0,7 s Vorlauf vor dem erkannten Sprachbeginn und kurze Stille vor der Erkennung',
    'App-Aktionen im Gespräch („Spiel Weihnachtslieder auf Spotify“) werden direkt ausgeführt statt nochmal nachzufragen – auch wenn das Gespräch in „Ergebnisse“ läuft',
  ]),
  ('1.63.0', [
    'Neu: „Ergebnisse“ – Abläufe, geplante Aufgaben, externe Aufrufe und Gespräche ohne offenen Chat landen an einem Ort statt in vielen einzelnen Chats',
    'Ergebnisse zeigen ihre Herkunft (⚙ Ablauf, ⏱ Geplant, 🎙 Gespräch, 🔌 Extern) und lassen sich filtern; Zahl neuer Ergebnisse in der Seitenleiste',
    'Bisherige Routinen-Chats werden automatisch in die Sammlung übernommen',
    'In der Sammlung tippen startet einen Chat mit dem Ergebnis als Zusammenhang',
    'Reaktionen: auf reine Mitteilungen antwortet der Agent mit 👍 an deiner Nachricht (und merkt sich Wichtiges), auf „Danke“/„passt“ sofort ohne Modell',
    'Rückfragen nur noch, wenn wirklich etwas fehlt',
  ]),
  ('1.62.0', [
    'Handy: Schnellmenü als runder Knopf rechts unten auf allen Unterseiten – mit einer Hand erreichbar (im Chat sitzt er rechts über der Eingabe)',
    'Schnellmenü: oben links öffnet das Menü, oben rechts die Leiste mit Artefakten & Metriken',
    'Anhänge und Bild-Vorschläge (Zusammenfassen, Text abschreiben …) stehen jetzt in einer wischbaren Zeile über der Eingabe statt den halben Bildschirm zu belegen',
    'Update-Download setzt nach Verbindungsabbruch automatisch fort (bis zu 8 Versuche, an derselben Stelle) statt mit „Connection closed“ abzubrechen; Fehlermeldungen ohne lange Download-Adresse',
  ]),
  ('1.61.0', [
    'Gespräch: App-Aktionen (z. B. Spotify) werden im Gespräch per Stimme bestätigt („Soll ich „Weihnachtslieder“ in Spotify abspielen?“) statt still als Karte im Chat zu liegen – und Junels behauptet nicht mehr, es laufe schon',
    'Begleiten öffnet die Seite sofort im Browser und liest das Formular selbst – ohne Umweg über Pläne; danach erklärt Junels das Formular und fragt gleich die ersten Angaben ab',
    'Begleiten erkennt Fehlerseiten (z. B. Formular-Link ohne konkretes Formular, abgelaufene Sitzung) und Anmeldeseiten (ID Austria) und reagiert passend: Formular selbst suchen, kurz nachfragen oder die Anmeldung übergeben',
    'Antworten zeigen keine Werkzeug-Namen wie „begleiten aktion plan“ mehr; unsinnige Tokens/s-Werte bei Cloud-Antworten werden nicht mehr angezeigt',
  ]),
  ('1.60.2', [
    'Fix: Steht der Chat auf „Gerät“, nutzt auch Begleiten nie die Cloud (vorher schlug Begleiten die Cloud vor, wenn sie im Chat einmal erlaubt war)',
    'Fix: 2442 API – lange Anfragen (z. B. mit Webseiten-Inhalt) werden auf die Höchstlänge des Servers gekürzt statt mit „Frage zu lang“ abzubrechen',
  ]),
  ('1.60.1', [
    'Amtsweg-Lotse und Begleiten sind jetzt ein Skill: /begleiten ohne Link klärt den Amtsweg (Unterlagen, Kosten, Fristen, Formular-Link) und begleitet dich danach durchs Formular, mit Link geht es direkt los. /amtsweg funktioniert weiterhin',
  ]),
  ('1.60.0', [
    'Gespräch: Junels redet nicht mehr über die Frage, seine Anweisungen oder den „Kontext“ – Meta-Sätze werden herausgefiltert; bei unverständlicher Frage (Spracherkennung verhört) fragt Junels kurz nach statt zu raten',
    'Begleiten hilft jetzt wirklich bei Formularen: liest alle Felder (auch Tabellen-Formulare der Ämter), erklärt sie in einfachen Worten, fragt höchstens 3 Angaben auf einmal und trägt sie ein',
    'Sensible Felder (SV-Nummer, Pass, IBAN, Passwort) hebt Junels violett mit Erklärung hervor – du tippst selbst, Junels liest den Wert nie',
    'Vor dem Absenden: Prüfung auf offene Pflichtfelder und Fehlermeldungen, Zusammenfassung, dann erst dein Ja',
    'Neuer Skill Amtsweg-Lotse (/amtsweg oder einfach fragen, z. B. „Ich ziehe um, was muss ich tun?“): Unterlagen-Checkliste, Schritte, Kosten, Fristen und Formular-Link aus oesterreich.gv.at und wien.gv.at – danach Begleitung durchs Formular',
    'Browser: Eintippen in Formularfelder schickt das Formular nicht mehr vorzeitig ab (Enter nur noch in Suchfeldern)',
  ]),
  ('1.59.0', [
    'Skills & Abläufe zusammengeführt: eine Liste für Skills, Abläufe, Zeitpläne und Beobachtungen – mit Filtern (Anleitung, Mit Ablauf, Zeitplan, Beobachtet, Probleme)',
    'Jeder Ablauf ist jetzt auch ein Skill: „/name Eingabe“ im Chat startet ihn, Schritte und Ergebnis erscheinen direkt im Chat. Bestehende Prozesse wurden automatisch übernommen',
    'Skills bekommen „Auslöser & Ablauf“: Zeitplan, Beobachtung oder weitere Schritte direkt im Skill-Editor anlegen',
    'Skill-Pakete enthalten den Ablauf (assets/junels-flow.json) – beim Import baut Junels ihn wieder auf, pausiert bis zum Einschalten; andere Agents lesen die Schrittliste',
    'Abläufe können andere Ablauf-Skills als Baustein nutzen (Unter-Ablauf)',
    'Seitenleiste aufgeräumt: „Skills & Abläufe“ und „Wissen & Vorlagen“',
  ]),
  ('1.58.0', [
    'Ausgabeformat wählbar: Karussell, Tabelle, Checkliste, Ablauf (Zeitleiste), Diagramm, Text oder Datei (PDF, Word, Excel, PowerPoint)',
    'Im Chat über den Knopf „Format“ über der Eingabe – oder „… als Tabelle“, „… als Checkliste“, „… Schritt für Schritt“ in der Nachricht',
    'Fertige Antworten umstellen: ⋯ → „Als Tabelle zeigen“ usw.; Tabellen mit „Als Excel speichern“, Checklisten zum Abhaken mit Fortschritt',
    'Ausgabe fest einstellen in Skills, in den Ablauf-Bausteinen Agent/Skill und bei Beobachtungen (z. B. Amazon-Suche immer als Karussell)',
    'Karten und Tabellen entstehen aus Suchergebnissen bzw. der Aufzählung der Antwort – verlässlich auch mit kleinen Modellen am Gerät',
  ]),
  ('1.57.0', [
    'Word-Dokumente erstellen: echte Formatvorlagen (Überschriften, Listen, Tabellen, Zitate, Bilder) – weiter bearbeitbar in Word, Pages und Google Docs',
    'Excel-Tabellen erstellen: mehrere Blätter, Zahlen/Datum/Prozent/Euro als echte Werte, Formeln (auch deutsch, z. B. =SUMME(B2:B9)), fixierte Kopfzeile und Filter; einfache Formeln werden vorgerechnet',
    'Word und Excel gezielt ändern: Zellen setzen, Zeilen anfügen, Blätter anlegen; Abschnitte ersetzen, einfügen, löschen, Text suchen und ersetzen',
    'Angehängte Word-/Excel-Dateien ändert Junels als Kopie – Original, Layout und Formatierung bleiben erhalten',
    'Vorschau von Word und Excel direkt im Chat; im Ablauf-Baustein „Speichern“ als PDF, Word oder Excel',
  ]),
  ('1.56.0', [
    'Skills im offenen Agent-Skills-Standard (agentskills.io, wie Claude, Codex, Cursor, Gemini CLI): SKILL.md mit name/description, Junels-Einstellungen (Werkzeuge, Internet, Modell …) unter metadata – andere Agents ignorieren sie, Junels liest sie wieder ein',
    'Skill teilen als Standard-Paket (.zip mit Ordner, SKILL.md und Dateien) – einzeln im Editor oder alle eigenen Skills auf einmal; „Standard prüfen“ zeigt, ob ein Skill konform ist',
    'Skill-Dateien: references/, scripts/ und assets/ aus importierten Paketen bleiben erhalten und lassen sich ansehen, ergänzen und entfernen; Skripte werden nie ausgeführt',
    'Stufenweises Laden: Junels kennt erst nur Name und Zweck deiner Skills, lädt die Anleitung, wenn eine passt, und Zusatzdateien erst bei Bedarf – spart Platz, gerade bei kleinen Modellen am Gerät',
    'Werkzeug-Übersetzung für Claude Code, Codex, Gemini CLI und OpenCode erweitert (auch Bash(git:*)-Schreibweise); was Junels nicht kann, steht sichtbar im Editor statt still zu verschwinden',
  ]),
  ('1.55.0', [
    'Skills importieren: Datei(en) (SKILL.md, .zip, .skill mit mehreren Skills), Link (GitHub-Seite, Ordner, Rohdatei) oder Text einfügen – auch Claude-Skills; Werkzeuge werden übersetzt oder passend vorgeschlagen, ein einzelner Skill öffnet sich zum Prüfen',
    'Skills: Internet je Skill (nachfragen, ohne Rückfrage erlaubt, gesperrt) und Modell je Skill (lokal, eigener Server, Cloud, Hybrid) – gilt im Chat und im Skill-Baustein',
    'Agent-Test-Satz in Stufen passend zur Modellgröße: Basis (bis ~4B), Fortgeschritten (~7B), Profi (ab ~10B und Cloud) – kleine Modelle werden nicht an Aufgaben für große gemessen; Vergleich nur bei gleichem Modell und gleicher Stufe',
    'Neue Test-Fälle: Folgefragen, mehrere Orte, Englisch, nichts gefunden, Überweisungs-Falle, Flug suchen + eintragen, Kalender + Mail, Recherche + Diagramm, unklarer Auftrag',
    'Englische Wetterfragen werden erkannt; „trag … in meinen Kalender ein“ trägt ein statt nur zu lesen (vom Test-Satz gefunden)',
  ]),
  ('1.54.2', [
    'Suchergebnisse gehen dem Modellwissen vor: Junels antwortet mit dem, was die Websuche liefert, statt mit einem veralteten Stand',
    '„Trag … ein“ und „Erinnere mich …“ führen direkt zum Vorschlag (du bestätigst wie gewohnt) statt zu einer Rückfrage',
    'Keine kaputten Formeln mehr in Antworten (z. B. bei Prozentrechnungen)',
  ]),
  ('1.54.1', [
    'Fragen zu deinen eigenen Daten (Kalender, Mails, Kontakte) und zu Dingen, die sich ändern („Wer ist der aktuelle …“): Junels sieht jetzt immer nach, statt zu raten – vom Test-Satz gefunden',
    'Spotify-Steuerung nur noch bei Musik-/App-Wünschen – „Such mir einen Flug“ oder „Beispiel“ lösen sie nicht mehr aus',
    'Prüfen & Nachbessern nur noch bei Informations-Aufträgen: Nach einer Aktion (Mail-Entwurf, Datei, Spotify) wird nichts wiederholt – keine doppelten Entwürfe',
  ]),
  ('1.54.0', [
    'Agent-Test-Satz: 34 typische Aufträge (Wetter, Kalender, Mail, Spotify, Präsentation, Rechnen …). Die Werkzeug-Auswahl wird bei jedem Build geprüft; mit deinem Modell unter Selbsttest → Agent-Test-Satz (Werkzeuge sind Attrappen, es wird nichts gesendet) – mit Vergleich zum letzten Lauf',
    'Agent-Harness: Chat, Prozesse, Team und externe Aufrufe laufen jetzt durch dieselbe Schicht – gleiche Regeln für Werkzeuge, Internet und Protokoll',
    'Mehrteilige Aufträge: Junels macht erst einen kurzen Plan, prüft am Ende, ob alles erledigt ist, und bessert einmal nach (im Agenten-Profil abschaltbar)',
    'Budget je Auftrag: höchstens X Minuten und X Tokens (Agenten-Profil, Standard 8 min / 120k)',
    'Lange Chats und Läufe: Was aus Platzgründen herausfällt, bleibt als Kurzfassung erhalten statt vergessen zu werden',
    'Prozesse: Zwischenstand nach jedem Baustein – wird Junels mitten im Lauf beendet, kommt eine Meldung und der Lauf lässt sich mit „Fortsetzen“ beim offenen Schritt weiterführen',
    'Bild-Wunsch wie „Fuchs im Schnee“ ruft nicht mehr das Wetter auf (vom Test-Satz gefunden)',
  ]),
  ('1.53.1', [
    'Mac-Update: Die neue Version wird jetzt im Browser geladen statt in der App – in der App geladene Updates hat macOS wegen der Sandbox-Quarantäne nicht gestartet („kann nicht geöffnet werden“)',
    'SSO-Anmeldung: Junels prüft die Server-Adresse und stellt automatisch auf die Agent-API um (z. B. sso.2442.io → agent.2442.io); klare Meldung, wenn dort keine Agent-API läuft',
    'SSO: „Mit SSO anmelden“ wird sofort aktiv, sobald eine Adresse eingetippt ist',
    'Schnellmenü am Mac kompakt und mittig statt über die ganze Breite (wurde unten abgeschnitten)',
  ]),
  ('1.53.0', [
    'Seitenmenü neu: Chats direkt unter der Suche (die letzten 5, dann „Alle x Chats anzeigen“); alle anderen Gruppen eingeklappt und aufklappbar',
    'Automatisierung: Geplante Aufgaben, Prozesse & Beobachtungen und ihre Ergebnis-Chats (früher „Routinen“) in einer Gruppe',
    'Benachrichtigungen nicht mehr im Menü, sondern nur oben an der Glocke – mit Punkt in der Farbe der wichtigsten neuen Mitteilung (Warnung rot, Aktion violett, Erinnerung gelb, Fertig grün, Info blau)',
    'KI-Weiche (lokal/hybrid/Cloud), Internet und Schnellmenü sitzen jetzt direkt über der Eingabe – die obere Leiste ist aufgeräumt',
    'Android: Menü schließt sich nach „Neuer Chat“, einem Chat oder einem Bereich; Seitenmenü, Artefakte und alle Auswahl-Fenster haben ein ✕ zum Schließen',
  ]),
  ('1.52.0', [
    'Alle Seiten durchgesehen und aufgeräumt – am Handy kein doppelter Seitentitel mehr, Erklärtexte kurz und dezent',
    'Prozesse am Handy als Schrittliste statt winzigem Canvas: Schritte antippen zum Bearbeiten, „Schritt hinzufügen“ unten; Canvas per Symbol oben umschaltbar',
    'Prozesse & Beobachtungen: deine Abläufe stehen oben, „Neu“ (+) fasst Ablauf beschreiben, Beobachten und Leeren Prozess zusammen; Listen ohne Knopf-Gedränge – Titel wieder lesbar („Jetzt ausführen“, „Jetzt prüfen“ im ⋮-Menü)',
    'Beobachtung im Detail: neueste Meldung oben statt ganz unten',
    'Geplante Aufgaben ohne Statistik-Kacheln; „Schnell einrichten“ statt „Vorlagen“ (Vorlagen heißen nur noch die Prompt-Vorlagen)',
    'Agent & Werkzeuge: Werkzeuge nach Themen gruppiert (Internet, Erstellen, Wissen & Dateien, Gerät & Apps …) mit Zähler',
    'Kalender, Gerät & Ordner: „Über dich“ zuerst, Kalender prüfen und Kalender-Abo in einer Karte',
    'Seitentitel = Namen im Menü und in den Einstellungen (Web-Zugänge, Tresor & Mail-Konto, Updates & Neuigkeiten …)',
    'Mac: Artefakt-Spalte erscheint nur, wenn der Chat Artefakte hat',
  ]),
  ('1.51.1', [
    'Konto, Datenschutz & Abgleich neu aufgebaut: Status ganz oben („Abgleich aktiv · zuletzt …“ mit „Jetzt“-Knopf), dann 3 klare Schritte – Was soll mit? → Sync-Passwort → Verbinden',
    'Verbinden: „Über Server“ oder „Nur im WLAN“ wählen – es wird nur angezeigt, was dazu gehört. Server-Adresse und SSO-Anmeldung stehen jetzt zusammen (vorher brauchte SSO eine Adresse, die erst weiter unten kam)',
    'Einzelne Kategorien, Server-Einrichtung und manuelle WLAN-Adresse unter „Einzeln anpassen“ bzw. aufklappbar; erledigte Schritte mit Häkchen',
    'Hängende Meldung „Anmeldung im Browser …“ verschwindet, wenn nichts mehr läuft; Hinweis zu geplanten Aufgaben steht jetzt bei den geplanten Aufgaben',
  ]),
  ('1.51.0', [
    'Einstellungen neu geordnet nach dem, was du erledigen willst: KI · Verbindungen · Alltag · Daten & Konto · Hilfe & Wartung – keine doppelten Einträge mehr',
    'Suche in den Einstellungen: z. B. „Kalender“, „Stimme“, „MCP“ führt direkt zum richtigen Bereich',
    'Neuer Bereich „Erweiterungen“: MCP-Store, Junels für andere Programme, Web-Zugänge und Apps steuern an einem Ort',
    '„Letztes Modell beim Start laden“ steht jetzt bei den Modellen statt bei der Darstellung; Darstellung & Designs zusammengelegt',
    'Menü: Heute · Automatisch erledigen · Fähigkeiten & Wissen · Kontrolle; Schnellnavigation in derselben Reihenfolge',
    'Einheitliche Begriffe: „Beobachtungen“ statt Watchlist, „Vorlagen“, „Aktivität & Überwachung“ (Überwachung jetzt dort zu finden)',
  ]),
  ('1.50.0', [
    'Prozesse: neuer Baustein „Team“ – mehrere Agenten mit Rollen arbeiten nacheinander (z. B. Recherche → Autor → Prüfer); der Prüfer kann Überarbeitungen verlangen. Je Mitglied eigener Skill und eigenes Modell',
    'Modellwahl je Baustein: Agent, Skill und Team-Mitglieder können lokal, auf deinem Server oder in der Cloud laufen',
    'Prozesse: neuer Baustein „Plattform“ – Workflows auf n8n, Dify, Flowise, Langflow oder einem eigenen Webhook aufrufen, Antwort wird übernommen',
    'Junels als MCP-Server: Claude Desktop, Cursor, n8n, Dify … können deine Skills und Prozesse als Werkzeuge nutzen – nur auf diesem Gerät, mit Schlüssel, Aktionen warten auf deine Freigabe (Einstellungen → MCP-Server)',
    'Überwachung: Läufe, Erfolgsquote, Dauer, Tokens und langsamste Bausteine je Prozess und externem Aufruf (Schnellnavigation oder Prozesse → Überwachung)',
    'Selbsttest prüft den MCP-Server und die Fehlerquote der Prozesse',
  ]),
  ('1.49.0', [
    'Prozesse: neuer Baustein „Skill“ – führt einen deiner Skills mit seinen Werkzeugen aus, Ergebnis geht an den nächsten Baustein',
    'Vorabprüfung erkennt gelöschte oder ausgeschaltete Skills',
    'Abgleich: eigene und angepasste Skills werden Ende-zu-Ende verschlüsselt über dein Konto synchronisiert (ab Stufe „Einstellungen“)',
  ]),
  ('1.48.0', [
    'Kalender-Abo (iCal): Google-Kalender und andere per geheimer iCal-Adresse einbinden – funktioniert auch, wenn das Konto nicht mit dem Gerät synchronisiert (Einstellungen → Gerät & Automatik)',
    'Abo-Termine erscheinen überall: Tagesüberblick, Morgen-Übersicht, „Was habe ich heute?“, Termin-Vorbereitung – inkl. Serien, Geburtstagen, abgesagten und ausgenommenen Terminen',
    'Selbsttest prüft das Kalender-Abo mit; Kalender prüfen zeigt die Abos',
  ]),
  ('1.47.1', [
    'Selbsttest und Benachrichtigungen direkt auf der ersten Einstellungsseite und im Raster (Schnell wechseln)',
  ]),
  ('1.47.0', [
    'Selbsttest (Einstellungen → Selbsttest): Junels prüft Speicher, Modell, Internet, Kalender, Zeitpläne, Prozesse, Watchlist, Werkzeuge, Skills und Sync – Bericht zum Kopieren/Teilen',
    'Nach jedem Update läuft der Selbsttest automatisch still im Hintergrund und meldet Probleme im Benachrichtigungscenter',
    'Jede neue Version muss vor der Veröffentlichung automatische App-Logik-Tests bestehen (Präsentation, Begleiten, Skills, Benachrichtigungen, Zeitpläne …)',
    'Prompt-Vorlagen: Vorlagen mit Zeitplan verschwinden nicht mehr aus der Liste – sie stehen mit „Zeitplan: täglich …“ unter Vorlagen und unter Geplant; Bestätigung nach dem Speichern',
    'Kalender prüfen: bricht nach 15 Sekunden mit einer klaren Meldung ab, statt zu hängen',
  ]),
  ('1.46.0', [
    'Skills: wiederverwendbare Fähigkeiten aus Anleitung + erlaubten Werkzeugen – aufrufen mit /befehl im Chat („/“ tippen zeigt alle)',
    'Eigene Skills entwerfen (Bereich „Skills“): Name, Wann nutzen, Anleitung, Werkzeuge, Pflicht-Ergebnis, Angaben, Wissen & Beispiele – mit „Testen“',
    'Basis-Skills aus den Werkzeugen: Präsentation, Dokument, Erinnerung, Tagesüberblick, Recherche, Begleiten, Liegengebliebenes, Musik & Apps – anpassbar und zurücksetzbar',
    'Ein Skill lädt nur seine Werkzeuge – dadurch arbeiten die Modelle am Gerät deutlich verlässlicher',
    '„Bau mir einen Skill, der …“ – Junels entwirft ihn selbst; unter jeder Antwort (⋯) „Als Skill speichern“',
    'Eigene Skills erkennt Junels automatisch, wenn die Nachricht passt; SKILL.md importieren, kopieren und teilen (kompatibel mit Claude-Skills)',
  ]),
  ('1.45.2', [
    'Beobachtung: Leiste oben aufgeräumt – „Jetzt prüfen“ und ⋮ (Bearbeiten, Canvas, Duplizieren, Entfernen); nichts überlagert mehr Zurück und Titel',
  ]),
  ('1.45.1', [
    'Schnellnavigation überall: das Raster gibt es jetzt auch im Chat (Handy oben statt Gesprächsmodus – der ist unten im Eingabefeld), am Desktop und in allen Bereichen',
  ]),
  ('1.45.0', [
    'Schneller navigieren: In jeder Unterseite oben rechts das Raster – direkt „Zum Chat“, „Neuer Chat“ oder in jeden Bereich springen, statt Seite für Seite zurück',
    'Bereiche stapeln sich nicht mehr: wer aus einem Bereich in einen anderen wechselt, ist mit einem Schritt zurück wieder im Chat',
  ]),
  ('1.44.1', [
    'Benachrichtigungen springen direkt ins Thema: Beobachtung öffnet die Beobachtung (nicht die Watchlist), Prozess-Fehler öffnen den Prozess – auch beim Antippen der Meldung am Mac',
    'Einstellungen → Gerät & Automatik → „Kalender prüfen“: zeigt, welche Kalender Junels sieht, wie viele Termine darin liegen und ob die Synchronisierung aus ist',
  ]),
  ('1.44.0', [
    'Benachrichtigungscenter: nichts verschwindet mehr von selbst – Meldungen bleiben, bis du sie archivierst',
    'Gelesen/ungelesen: je Meldung (Wischen nach rechts oder Menü ⋮) und für alle auf einmal; Filter „Ungelesen“',
    'Schnell-Aktionen je Meldung: Öffnen (Absprung in Chat/Watchlist), Erledigt, Schlummern, Archivieren, Löschen',
    'Archiv: Wischen nach links archiviert (mit Rückgängig), „Gelesene archivieren“, Archiv ansehen und wiederherstellen',
  ]),
  ('1.43.0', [
    'Neuer Bereich „Benachrichtigungen“ (Glocke oben und in der Seitenleiste unter „Übersicht“): sammelt alles, was auf dich wartet, und alle Meldungen',
    '„Zu tun“ zeigt offene Freigaben aus allen Chats (Mail, WhatsApp, App-Aktionen), laufende Begleitungen mit aktuellem Schritt, Gedächtnis-Einträge zum Bestätigen, fällige Erinnerungen und offene Aktionen – direkt mit Knöpfen',
    'Darunter: Geplant, Heute, Früher – filterbar nach Art; die Zahl an Glocke und Seitenleiste zeigt, wie viel offen ist',
  ]),
  ('1.42.1', [
    'Kalender (Android): ganztägige Termine wie Geburtstage erscheinen am richtigen Tag (wurden wegen UTC einen Tag zu spät angezeigt)',
    'Kalender: wiederkehrende Termine tauchen nicht mehr fälschlich jeden Tag auf',
    'Kalender: Sind nur Geburtstage/Feiertage zu sehen und die Google-Kalender leer, sagt Junels, dass die Kalender-Synchronisierung vermutlich aus ist',
  ]),
  ('1.42.0', [
    'Erinnerungen: „Erinnere mich morgen um 9 an …“ – auf Wunsch zusätzlich als Kalendertermin („… und trag es in den Kalender ein“)',
    'In der Meldung: „Schlummern 10 Min“, „1 Std“ und „Erledigt“ – funktioniert auch bei geschlossener App (Android und Mac)',
    'Mitteilungen: geplante Erinnerungen unter „Geplant“, fällige unter „Wartet auf dich“ – Schlummern (10 Min, 1 Std, Morgen) und Schieberegler „Erledigt“',
    'Art der Benachrichtigung selbst wählen: bei Beobachtungen (Watchlist-Dialog), geplanten Prompts und im Prozess-Baustein „Push-Nachricht“ – oder „Automatisch“',
    'Der Agent wählt die Art selbst (Erinnerung, Aktion, Warnung, Ergebnis, Info)',
  ]),
  ('1.41.0', [
    'Benachrichtigungen mit Art, Farbe und Symbol: Aktion (violett, Hand), Warnung (rot, Dreieck), Erinnerung (bernstein, Wecker), Ergebnis (mint, Haken), Info (blau, i)',
    'Android: eigener Kanal je Art (Ton/Vibration im System einstellbar), farbiges Symbol in der Meldung; Mac: Untertitel und Symbol-Bild je Art',
    'Mitteilungen (Glocke oben): alles gesammelt, „Wartet auf dich“ zuerst, Filter nach Art; violetter Punkt = Aktion offen, roter = Warnung',
    'Einstellungen → Benachrichtigungen: Arten an/aus, Ruhezeit (Aktionen und Erinnerungen kommen durch), Infos optional einmal täglich',
    'Prozesse: Art im Baustein „Push-Nachricht“ wählbar; Fehler in Prozessen melden sich als Warnung, Grenzwerte der Watchlist ebenso',
  ]),
  ('1.40.0', [
    'Prozesse duplizieren: Menü ⋮ in der Liste oder „Duplizieren“ in den Prozess-Einstellungen – die Kopie startet pausiert und öffnet sich zum Anpassen',
    'Watchlist: Einträge duplizieren (Dialog mit allen Einstellungen vorausgefüllt) und bearbeiten – Menü ⋮ in der Liste oder oben im Eintrag',
    'Beobachtungen aus Prozessen lassen sich jetzt auch im einfachen Dialog bearbeiten (Ziel, Intervall, Schwellenwert …), nicht nur im Canvas',
  ]),
  ('1.39.1', [
    'Kalender (Android): liest Termine zusätzlich direkt aus der Termin-Tabelle, falls die Tagesansicht des Systems leer bleibt',
    'Kommen keine Termine, sagt Junels, welche Kalender es sieht und ob die Kalender-Synchronisierung aus ist',
  ]),
  ('1.39.0', [
    'Begleiten: Link posten („Mach das mit mir: …“) – Junels führt dich Schritt für Schritt durch Amtswege, Tickets, Buchungen und Käufe',
    'Plan mit Häkchen über dem Chat, und du siehst live, was Junels im Browser tut',
    'Übergabe an dich bei Anmeldung (ID Austria, Passkey), Captcha und Zahlung – Bezahl-Knöpfe drückt Junels nie',
    'Warten & melden: Warteschlange oder Seite beobachten, Benachrichtigung, sobald du dran bist',
    'Geschaffte Abläufe als Vorlage speichern; bei eingerichtetem Cloud-Modell fragt Junels, ob es dafür genutzt werden darf',
    'Prozesse: Live-Ansicht, was der laufende Agent-Schritt gerade tut; Stoppen bricht ihn sofort ab, nach 10 Minuten Zeitlimit',
    'Spotify: „Spiel Jazz“ bzw. „abspielen“ nach einer Suche spielt jetzt das Gesuchte statt des alten Titels (Android direkt, Mac über einen gefundenen Spotify-Link)',
  ]),
  ('1.38.4', [
    'Apps steuern: „Such nach Jazz“ funktioniert jetzt – auch ohne App-Namen (nimmt die freigegebene Musik-App)',
    'Spotify-Suche öffnet direkt in der App; am Mac wird Spotify vorher gestartet, damit die Suche nicht verloren geht',
    'Android: Spotify, YouTube Music, Deezer & Co. werden zusätzlich direkt gesucht und erscheinen in der Liste',
  ]),
  ('1.38.3', [
    'Eigene Designs: auch aus einer PDF übernehmen (Farben von der ersten Seite)',
  ]),
  ('1.38.2', [
    'SSO-Anmeldung springt nach dem Login direkt per App-Link zurück in Junels – kein endlos ladender Browser mehr (braucht Agent-API v2)',
    'Der Anmelde-Code gilt nur einmal, 10 Minuten und nur zusammen mit einem geheimen Prüfwert dieses Geräts',
    'Apps steuern: Spotify und andere Apps erscheinen jetzt in der Liste (Android: Sichtbarkeit der Apps repariert; Mac: auch Unterordner und ~/Programme)',
  ]),
  ('1.38.1', [
    'Junels Agent-API hinter der Weiche (Kanäle Prod/Q/T, Verwaltung, Abnahme, Rollback): nur noch Klar-URLs – /login/<port>, /sync, /whoami, /logout, /wipe; Rücksprung an die App als /sso/<token>',
    'SSO-Anmeldung läuft jetzt über die Agent-API; die einzelne Datei junels-sync.php bleibt für den Abgleich ohne SSO',
  ]),
  ('1.38.0', [
    'Geräte-Setups: Einstellungen als „Desktop“, „Handy“ … speichern und anwenden; nach einer Wiederherstellung bekommt jedes Gerät sein eigenes Setup zurück',
    'Apps öffnen & steuern (z. B. Spotify): nur Apps aus deiner Freigabeliste – öffnen, Wiedergabe steuern, Suche öffnen. Nie tippen, kaufen, bestellen oder bezahlen; Bank/Shop-Apps nur öffnen; optional mit Rückfrage und nur, wenn du dabei bist',
    'Konto & Datenschutz-Stufen 0–4: von „Nur dieses Gerät“ bis „Alles“ – immer Ende-zu-Ende verschlüsselt; Daten auf dem Server mit einem Tipp löschen',
    'Anmeldung mit SSO (z. B. sso.2442.io) über den eigenen Sync-Server: nur dein Konto darf speichern, jede Person hat ihren eigenen Bereich',
    'Abgleich jetzt auch für Geräte-Setups und eigene Designs',
  ]),
  ('1.37.1', [
    'Korrektur: In 1.37.0 konnte die Stimme vor jedem Satz lange warten (wirkte stumm). Jetzt wird höchstens einmal am Anfang kurz gepuffert (max. 5 s) – und nur, wenn es hilft',
    'Stimme nutzt wieder weniger Prozessorkerne, damit sie und das Sprachmodell sich nicht gegenseitig bremsen',
  ]),
  ('1.37.0', [
    'Stimme ohne Stocken: Junels misst das Tempo der Stimme und puffert kurz vor dem Sprechen – danach läuft die Antwort ohne Pausen durch. Die schöne KI-Stimme bleibt (keine automatische Gerätestimme mehr)',
    'Mehr Rechenkraft für die Stimme: Piper und Kokoro nutzen jetzt mehr Prozessorkerne',
    'Schnellere KI-Stimme: Ist die Stimme auf dem Gerät zu langsam, schlägt das Gespräch eine ähnlich klingende, 3–5× schnellere Piper-Stimme vor (ein Tipp: laden & verwenden). Neue Handys starten gleich mit Piper',
  ]),
  ('1.36.0', [
    'Gespräch & Vorlesen ohne lange Pausen: Ist die gewählte Stimme auf dem Gerät langsamer als Echtzeit, spricht Junels automatisch mit der Gerätestimme weiter (und merkt sich das; in den Gesprächs-Einstellungen umkehrbar)',
    'Offline-Erkennung: Junels merkt, wenn kein Netz da ist – zeigt „Kein Netz“, lässt Internet-Werkzeuge weg, antwortet mit dem Modell auf dem Gerät statt der Cloud und holt Beobachtungen nach, sobald das Netz zurück ist',
  ]),
  ('1.35.1', [
    'Antworten in deiner Sprache: Fragst du auf Französisch, Englisch, Italienisch oder Spanisch, antwortet der Agent auch so',
    'Flüge, Hotels, Bahn und aktuelle Preise: Der Agent öffnet direkt eine passende Seite im Browser (z. B. Google Flights) statt aufzugeben',
    'Internet-Suche wird auch bei Fragen auf Englisch, Französisch, Italienisch und Spanisch angeboten',
  ]),
  ('1.35.0', [
    'Posteingang lesen: Mit dem Mail-Konto (IMAP) prüft Junels unbeantwortete und ungelesene Mails – nur Absender, Betreff, Datum, ohne etwas im Postfach zu ändern',
    '„Was ist liegengeblieben?“ zeigt jetzt auch unbeantwortete Mails (ohne Newsletter) – auch ohne MCP-Werkzeug',
    'Neuer Chat: jeder Klick öffnet einen weiteren neuen Chat, beliebig viele',
  ]),
  ('1.34.0', [
    'Chats anheften und in Ordnern bzw. Projekten sortieren; Chats umbenennen (⋯ an jedem Chat)',
    'Eigene Designs speichern (Firmen-CI): aus PowerPoint mit Folienmaster, Word, Excel, Logo oder von Hand – als Standard oder per Name',
    'Liegengebliebenes aufspüren: offene Rückfragen, Vorhaben, fehlgeschlagene Prozesse, Beobachtungen, Termine und – mit verbundenem Werkzeug – Mails und Tickets',
    'Android: Widget „Frag Junels“ für den Startbildschirm (neuer Chat oder Gespräch per Mikrofon)',
    'Mac: „An Junels senden“ im Dienste-Menü für markierten Text und Links; Kurzbefehle per junels://frage?text=…',
    'Sicherung: alle Chats, Prozesse, Beobachtungen, Einstellungen, Gedächtnis und Designs als ZIP exportieren und wiederherstellen',
  ]),
  ('1.33.0', [
    '„Folie 3 überarbeiten“: einzelne Folien oder Abschnitte einer erstellten Präsentation bzw. eines PDFs gezielt ändern, einfügen oder löschen – Design und Rest bleiben',
    'Vorschau erstellter PowerPoints und PDFs im Artefakt-Bereich: Folien als Bilder, groß zum Durchblättern',
  ]),
  ('1.32.0', [
    'Beobachtungen mit Schwellenwert: „Melde dich, wenn die Nvidia-Aktie unter 120 fällt“ – Börsenkurs oder Zahl auf einer Webseite, Meldung nur beim Über-/Unterschreiten',
    'Wochenrückblick je Thema: sonntags ein Absatz statt vieler Einzeltreffer (zusätzlich oder statt Einzelmeldungen)',
    'Doppelte Meldungen werden zusammengefasst – dieselbe Nachricht aus mehreren Quellen nur einmal',
    'Verlauf: „Neu“-Filter, Neu-Markierung und einzelne Meldungen als ungelesen markieren',
  ]),
  ('1.31.6', [
    'Neuer KI-Anbieter „2442 API“ (api.2442.io): mit API-Schlüssel, optionalen Favoriten (z. B. groq,gemini) und Hinweis, wenn ein Favorit keine Credits mehr hat',
  ]),
  ('1.31.5', [
    'Mac: Nach dem Update startet Junels wieder zuverlässig – die alte Version beendet sich jetzt sofort, statt beim Aufräumen der KI-Engine hängen zu bleiben',
  ]),
  ('1.31.4', [
    'Ein neuer Chat steht sofort in der Chat-Liste – auch bevor du etwas abschickst (höchstens ein leerer Entwurf)',
  ]),
  ('1.31.3', [
    'Beobachtungen: Das Thema bleibt oben stehen, der Verlauf läuft wie im Chat – neuester Beitrag unten im Blick, ältere nach oben scrollen',
  ]),
  ('1.31.2', [
    'Präsentationen werden jetzt zuverlässig als Datei erstellt: Beschreibt der Agent nur Folien oder schreibt eine Anleitung, wird er zum Erstellen angehalten – notfalls baut die App die PowerPoint selbst aus dem Folienplan',
    'Design-Links (z. B. slidesgo) werden nicht mehr im Browser geöffnet, sondern direkt als Vorlage übernommen – inklusive Folien-Vorschauen für genauere Farben',
    'Design-Vorschläge als Folgenachricht („hier sind Design-Vorschläge …“) gehören automatisch zur vorigen Präsentation',
  ]),
  ('1.31.1', [
    'Drei neue Reise-Designs: Landschaft (Berge, Sonne), Vintage (Scrapbook mit Klebestreifen) und Nacht (Sterne, Mond, dunkle Folien) – der Agent wählt passend zur Stimmung',
  ]),
  ('1.31.0', [
    'Designs & Vorlagen: Präsentationen im passenden Stil zum Thema (z. B. Reise mit Flugroute, Reiseroute und Fortschrittsleiste als roter Faden)',
    'Eigene PowerPoint-, Word- und Excel-Dateien sowie Beispielbilder und Vorlagen-Links werden als Design-Vorlage übernommen',
    'Word, Excel und PowerPoint können jetzt angehängt und gelesen werden',
    'KI-Modus pro Chat wählbar: Am Gerät, On-Prem, Cloud oder Hybrid (zuerst Gerät, dann On-Prem oder Cloud)',
    'Scrollen funktioniert jetzt auch, während der Agent denkt – mit „Zum Ende“-Knopf',
  ]),
  ('1.30.0', [
    'Kommentar während der Arbeit: im selben Chat weiterschreiben, während der Agent arbeitet – er berücksichtigt den Kommentar sofort (eine entstehende Antwort wird damit neu begonnen); kommt er zu spät, wird er danach beantwortet',
    'In den Denkschritten steht, ab wann dein Kommentar berücksichtigt wurde',
  ]),
  ('1.29.0', [
    'Automatische Modellwahl: Alltagsfragen beantwortet das schnelle Modell (z. B. Qwen), Analysen, Code, Präsentationen und lange Texte das starke (z. B. Gemma); scheitert das schnelle, übernimmt das starke',
    'Speicherschonend: mit genug Arbeitsspeicher bleiben beide geladen, sonst wird das große Modell schon beim Tippen einer komplexen Anfrage geladen und nach einer Pause wieder freigegeben',
    'Unter jeder Antwort steht, welches Modell geantwortet hat',
    'KI-Symbol in Bildern kleiner und dichter am Rand',
    'Updates und Versionsverlauf auf einer Seite',
    'Mac: Junels beendet sich beim Update selbst – die App lässt sich dann einfach ersetzen, Löschen ist nicht mehr nötig',
  ]),
  ('1.28.0', [
    'KI-Kennzeichnung nach EU-Vorgaben: erzeugte Bilder tragen das offizielle Symbol „AI GENERATED“ fest im Bild (bleibt beim Teilen erhalten) und eine maschinenlesbare Kennzeichnung in der Datei',
    'Unter jeder Antwort – auch im Gesprächsmodus – das EU-Symbol „AI“ mit dem Hinweis „Mit KI erzeugt · KI kann Fehler machen“',
    'PDFs und PowerPoints haben auf jeder Seite bzw. Folie eine Fußzeile mit dem KI-Hinweis',
    'Präsentationen: erzeugte Bilder landen jetzt wirklich in der PowerPoint (Dateinamen mit Leerzeichen gingen verloren); vorher erzeugte Bilder kommen automatisch auf Folien ohne Bild, und „… mit Bildern“ erzeugt passende Bilder',
    'Hilfe: neuer Artikel „KI-Kennzeichnung“',
  ]),
  ('1.27.0', [
    'Präsentationen und Dokumente bekommen ihre Bilder automatisch, sobald das Bildmodell geladen ist (Handy bis 3, Mac bis 6 Bilder) – auch aus „Bild-Idee: …“-Zeilen',
    'Bilder erzeugen bricht nicht mehr nach 20 Sekunden ab: Werkzeuge haben eigene Zeitgrenzen (Bild 8 min, Präsentation mit Bildern 15 min)',
  ]),
  ('1.26.0', [
    'Routinen: jede geplante Aufgabe und jeder Prozess hat einen eigenen Chat (Kategorie „Routinen“) – dort landen nur die Ergebnisse, z. B. jeden Morgen um 7 die Morgen-Übersicht im selben Chat',
    'Keine erfundenen Links mehr: Adressen, die in keiner Quelle vorkamen, werden entfernt; Karten nur noch aus echten Treffern',
    'Karussell mit Kategorien: jede Karte zeigt ihr Thema (z. B. KI, Österreich, Suche: …), oben Filter nach Kategorie; die Morgen-Übersicht fasst Nachrichten nur kurz zusammen',
    'Websuche robuster: bei „keine Treffer“ vereinfachte Anfrage und Rückfall auf Google News; gesperrte Suchmaschinen werden benannt',
    'Prozesse: Suche ohne Treffer ist ein Fehler mit Hinweis (statt Werkzeug-Text als Ergebnis); {{vorher}} nach dem Auslöser ist leer',
    'Gespräch deutlich schneller: gleicher vorgerechneter Verlauf wie im Chat (vorher wurde der ganze Chat neu gerechnet – 15 s bis zum ersten Wort)',
    'Neue Wahl „Stimme des Geräts“ (z. B. Google-Sprachausgabe): klingt natürlich, ohne Pausen; Hinweis, wenn eine Stimme für das Gerät zu langsam ist',
    'Whisper-Füllwörter wie „bitte“ oder „danke“ allein lösen keine Antwort mehr aus',
  ]),
  ('1.25.0', [
    'Watchlist ist Teil der Prozesse: jede Beobachtung ist ein Auslöser „Beobachten“ im Canvas, an den du weitere Schritte hängst',
    'Watchlist: prüft auf Wunsch jede Minute (1, 5, 10, 15, 30 Minuten … wöchentlich), Suchanfragen wie bei Google ("Phrase", -ohne, site:, OR), Beschreibung in eigenen Worten mit Relevanzprüfung durch den Agenten, „Nur Aktuelles“ und „Jetzt testen“',
    'Canvas: neue Bausteine Web-API (REST mit API-Schlüssel, Token, Benutzer/Passwort oder OAuth/SSO wie Google, Microsoft, GitHub, eigener OpenID-Anbieter) und MCP-Server-Tool',
    'Canvas: Vorab-Check vor dem Start (Modell, Internet, Zugänge, Erreichbarkeit) mit Lösungsvorschlägen',
    'Canvas: Stopp-Knopf, animierter Ablauf (aktueller Schritt, Fortschritt, Datenfluss), Fehler mit Hinweis – „Agent beheben lassen“, „Selbst ändern“ oder „ab hier erneut“',
    'Canvas am Handy: Verbinden per Tippen (Punkt, dann Ziel) und „Verbinden mit …“, große Tippflächen, logisches Auto-Verbinden, untere Leiste ohne Überlappung',
    'Gespräch: Stimme wird vorab geladen, nächste Sätze entstehen schon während des Sprechens – keine Pause mehr nach dem ersten Satz; „Moment …“, wenn der Agent im Internet nachsieht',
    'Stimme klingt besser: Lautstärke angeglichen, keine Knackser, Abkürzungen/Uhrzeiten/Grad/Prozent/Euro ausgesprochen, keine Bluetooth-Telefonqualität mehr; Probehören in den Einstellungen',
  ]),
  ('1.24.0', [
    'Neues Design: Graphit und Mint, Schrift Inter, ruhige Karten mit feinen Rändern, Statuschips – hell und dunkel',
    'Menü neu geordnet: Automatik (Geplante Aufgaben, Prozesse, Watchlist), Arbeitsbereich (Prompt-Vorlagen, Wissen, Aktivitäten), Chats mit Suche; Einstellungen und Hilfe unten',
    'Auf dem Mac öffnen sich Bereiche rechts neben der Seitenleiste statt als eigene Seite',
    'Geplante Aufgaben: alle Aufträge mit Zeitplan an einem Ort (auch Morgen-Übersicht und Morning Briefing), Vorlagen zum Anlegen',
    'Einstellungen an einem Ort: Lokale Modelle, KI-Anbieter, Agent & Werkzeuge, Sprache, Gerät & Verbindungen, Darstellung',
    'Hilfe: alle Funktionen mit Erklärung, Bildschirmfoto und Suche',
    'KI-Anbieter: eigener Server (Ollama, LM Studio, vLLM …) oder Cloud (OpenAI, Anthropic, Gemini, Mistral, OpenRouter); nur lokal, nur On-Prem, nur Cloud oder „lokal zuerst, Cloud nach Freigabe“ (Einmal / Ganzer Chat); Schlüssel im Tresor',
    'Watchlist: Webseiten und Themen beobachten, Änderungen zusammenfassen und per Push melden',
    'Prozesse: Abläufe aus Bausteinen auf einem Canvas bauen (Auslöser, Agent, Werkzeug, Bedingung, Push, Speichern) – oder per Prompt erzeugen lassen; nach Zeitplan, bei Watchlist-Änderungen oder per Klick',
  ]),
  ('1.23.0', [
    'Freigabe-Karten: E-Mail- und WhatsApp-Entwürfe erscheinen als Karte mit „Senden“, „Bearbeiten“, „Verwerfen“ – im Gespräch genügt „Ja“',
    'E-Mails direkt aus Junels senden (eigenes Mail-Konto, Passwort im Tresor) – sonst öffnet „Senden“ die Mail-App',
    'Geplante Aufgaben: eigene Seite mit Schaltern, „Jetzt ausführen“ und Vorlagen',
    'Termine vorbereiten: pro Termin eine einseitige Notiz (Firma, Webseite, Fragen, Ziele) als Dokument im Chat',
    'Nach Terminen: Push-Nachricht „Folgemail entwerfen?“ – ein Tipp öffnet den Entwurf',
    '„Was hat der Agent getan?“: Verlauf aller Aktionen mit deiner Freigabe – lokal, 0 €',
    'Tresor: Passwörter und MCP-Anmeldungen liegen im Android-Keystore bzw. macOS-Schlüsselbund, nicht mehr in den App-Dateien',
    'Browser: Privat anmelden – Junels liest Eingabefelder nie aus (Passwörter blieben vorher nicht in jedem Fall verborgen)',
    'Gedächtnis: Bereiche (Vorlieben, Personen, Routinen), neue Einträge erst nach deiner Bestätigung, sensible Themen standardmäßig aus',
  ]),
  ('1.22.0', [
    'Systemcheck: „Schnell einrichten“ mit zwei Knöpfen – Handy- oder Desktop-Set (Sprachmodell, Spracherkennung, Stimme), nur Modelle, die auf diesem Gerät laufen',
    'Gespräch: Internet-Freigabe wird zuerst gesprochen und per „Ja“/„Nein“ beantwortet – oder per Knopf am Gesprächsbildschirm, kein Dialog mehr',
    'Gespräch: Der Agent beginnt nicht mehr mit den Worten deiner Frage',
    'Build: GitHub-Aktionen auf aktuelle Versionen (Node 24)',
  ]),
  ('1.21.2', [
    'Gespräch: „Regenbogen“, „Windows“ & Co. lösen keine Wetterabfrage mehr aus (die Antwort kam deshalb erst nach 25 s)',
    'Gespräch: Die erste Frage nach dem Öffnen geht ohne Namen; nach jeder Antwort 20 s Zeit für Nachfragen ohne Namen',
    'Gespräch: Wird etwas ohne Namen ignoriert, steht jetzt am Bildschirm, was gehört wurde und warum nichts passiert',
    'Wetter: „Heimatort“ als Ort wird als dein eingestellter Heimatort verstanden',
  ]),
  ('1.21.1', [
    'Push-Nachricht, wenn der Agent fertig ist und du nicht dabei bist (App im Hintergrund oder anderer Chat offen)',
    'Während der Agent arbeitet, kannst du andere Chats öffnen und neue anlegen; Nachrichten dort warten und werden danach beantwortet',
    'Gespräch: Der Agent spricht zu Ende – unterbrechen nur per Tipp auf den Kreis oder mit seinem Namen (Reinreden einschaltbar). Jede Unterbrechung steht im Log',
    'Browser: wartet auf nachgeladene Inhalte, erkennt Einträge auch ohne Bilder, Themenfilter nur wenn genannt („… zu Anthropic“)',
    'Nachfragen zu einer Webseite landen nicht mehr im News-Feed',
    'Denkschritte bleiben eingeklappt (wurden manchmal von einer anderen Nachricht aufgeklappt übernommen)',
  ]),
  ('1.21.0', [
    'Neue Spracherkennung: Canary (146 MB) und Parakeet (464 MB) über sherpa-onnx – im Test 4–5× schneller als Whisper small, mindestens so genau. Systemcheck → Spracherkennung',
    'Text-Chat: wiederholte Frage und lautes Denken am Anfang der Antwort werden ausgeblendet (wie im Gespräch)',
    'Browser: genannte Webseiten (z. B. „geh auf rtb.li/p/ainews …“, „Sportnews auf krone.at“, „auf anyai.fyi nach … suchen“) werden direkt geöffnet bzw. dort gesucht',
    'Keine Wiederholungen mehr: dieselbe Suche wird nicht mehrmals abgeschickt; nach zwei erfolglosen Versuchen antwortet der Agent',
  ]),
  ('1.20.3', [
    'Gespräch: Wiederholt der Agent deine Frage oder denkt laut („Der Nutzer möchte …“, „Du fragst …“), wird das nicht vorgelesen – nur die Antwort',
  ]),
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

/// Versionsverlauf steht jetzt auf der Seite „Updates & Versionsverlauf“.
Future<void> openChangelog(BuildContext context) => openUpdates(context);

/// Versionsverlauf: die neuesten [expanded] Versionen offen, ältere eingeklappt.
class ChangelogList extends StatelessWidget {
  const ChangelogList({super.key, this.expanded = 3});
  final int expanded;

  Widget _version(BuildContext context, String v, List<String> items) {
    final t = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    return Panel(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Version $v', style: t.titleSmall),
          if (v == appVersion) ...[
            const SizedBox(width: 8),
            StatusChip('installiert', color: c.mint, soft: c.mintSoft, dense: true),
          ],
        ]),
        const SizedBox(height: 6),
        for (final i in items)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('•  ', style: t.bodyMedium),
              Expanded(child: Text(i, style: t.bodyMedium)),
            ]),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recent = changelog.take(expanded).toList();
    final older = changelog.skip(expanded).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (v, items) in recent) _version(context, v, items),
      if (older.isNotEmpty)
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text('Ältere Versionen (${older.length})'),
          children: [for (final (v, items) in older) _version(context, v, items)],
        ),
    ]);
  }
}

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
      appBar: JAppBar(
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
