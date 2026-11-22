// Hilfe: alle Funktionen mit Erklärung, Bildschirmfoto und Suche.
// Die Bildschirmfotos entstehen beim Build automatisch (test/help_screenshots_test.dart)
// und liegen unter assets/help/<shot>.png – fehlt eines, wird es einfach weggelassen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'markdown_lite.dart';
import 'nav.dart';
import 'settings_page.dart';
import 'system_check.dart';
import 'theme.dart';

class HelpArticle {
  const HelpArticle({
    required this.id,
    required this.category,
    required this.icon,
    required this.title,
    required this.summary,
    required this.body,
    this.keywords = '',
    this.shot,
    this.open,
  });
  final String id;
  final String category;
  final IconData icon;
  final String title;
  final String summary;
  final String body;
  final String keywords;

  /// Name des Bildschirmfotos unter assets/help/ (ohne Endung).
  final String? shot;

  /// Ziel des Knopfs „Öffnen“.
  final String? open;
}

const helpCategories = ['Erste Schritte', 'Chat', 'Sprache', 'Automatik', 'Wissen', 'Modelle & Anbieter', 'Verbindungen', 'App & Sicherheit'];

const helpArticles = <HelpArticle>[
  // ------------------------------------------------------------ Erste Schritte
  HelpArticle(
    id: 'start',
    category: 'Erste Schritte',
    icon: Icons.waving_hand_outlined,
    title: 'Willkommen bei Junels',
    summary: 'Ein KI-Agent, der auf deinem Gerät läuft – ins Internet nur mit deiner Freigabe.',
    shot: 'overview',
    keywords: 'einführung überblick start offline lokal datenschutz',
    body: '''Junels ist ein persönlicher KI-Agent für Mac und Android. Das Sprachmodell läuft **auf deinem Gerät** – deine Fragen, Dateien und Notizen verlassen es nicht.

**So ist die App aufgebaut**
- **Links** die Seitenleiste: Modellstatus, Neuer Chat, Gesprächsmodus, Automatik (Geplante Aufgaben, Prozesse & Watchlist), Arbeitsbereich (Prompt-Vorlagen, Wissen, Aktivitäten) und deine Chats. Ganz unten Einstellungen und Hilfe.
- **In der Mitte** der Chat mit Eingabefeld.
- **Rechts** Artefakte (erzeugte Dokumente, Tabellen, Diagramme) und Metriken.

Am Handy öffnest du die Seitenleiste über ☰ oben links, die Artefakte über das Symbol oben rechts.

**Erste Schritte**
1. Systemcheck öffnen und „Handy-Set“ bzw. „Desktop-Set“ laden.
2. Einen neuen Chat beginnen und lostippen – oder den Gesprächsmodus starten.
3. Bei Bedarf das Internet für einen Chat freigeben.''',
  ),
  HelpArticle(
    id: 'systemcheck',
    category: 'Erste Schritte',
    icon: Icons.speed_outlined,
    title: 'Systemcheck & Modelle laden',
    summary: 'Prüft dein Gerät und lädt nur Modelle, die darauf auch laufen.',
    shot: 'systemcheck',
    open: 'systemcheck',
    keywords: 'modell download gguf ram speicher handy-set desktop-set context qwen gemma llama',
    body: '''Der Systemcheck misst Arbeitsspeicher, Prozessor und freien Platz und ordnet dein Gerät einer Klasse zu.

**Schnell einrichten**
- **Handy-Set** bzw. **Desktop-Set** lädt mit einem Tipp ein passendes Sprachmodell, eine Spracherkennung und eine Stimme.
- Es werden nur Modelle angeboten, die in den Arbeitsspeicher passen.

**Einzeln laden**
Unter den Abschnitten Sprachmodelle, Spracherkennung, Stimmen und Bildmodelle kannst du jedes Modell einzeln laden, entfernen oder eine eigene Adresse (Hugging Face) angeben.

**Eigene Datei**
Unter Einstellungen → Lokale Modelle → „Eigene Datei laden“ wählst du eine .gguf-Datei vom Gerät.

**Context**
Bestimmt, wie viel Text das Modell auf einmal sieht. „Auto“ wählt den größten sinnvollen Wert für dein Gerät.''',
  ),
  HelpArticle(
    id: 'chat',
    category: 'Erste Schritte',
    icon: Icons.forum_outlined,
    title: 'Chatten',
    summary: 'Fragen stellen, bearbeiten, wiederholen und mehrere Chats parallel nutzen.',
    shot: 'chat',
    keywords: 'nachricht senden stopp bearbeiten wiederholen kopieren denkschritte dauer suche chats kommentar ergänzen nachschieben',
    body: '''Schreib deine Frage ins Feld unten und tippe auf den Pfeil. Während der Agent arbeitet, wird der Pfeil zum **Stopp**-Knopf.

**Unter deiner Nachricht**
- ✏️ bearbeiten und neu senden
- ↻ wiederholen
- Kopieren

**Denkschritte** – benutzt der Agent Werkzeuge, siehst du über der Antwort eine eingeklappte Liste der Schritte. Ein Tipp klappt sie auf.

**Kommentar während der Arbeit** – während der Agent noch arbeitet, kannst du im selben Chat weiterschreiben („bitte nur unter 150 €“, „kürzer“, „auf Englisch“). Der Pfeil wird dann zum Kommentar-Knopf: Der Agent übernimmt den Kommentar sofort in den laufenden Auftrag – eine Antwort, die gerade entsteht, wird mit dem Kommentar neu begonnen. Ist die Antwort schon fertig, wird der Kommentar danach normal beantwortet. Mit leerem Feld bleibt der Knopf der **Stopp**-Knopf.

**Mehrere Chats** – während eine Antwort entsteht, kannst du andere Chats öffnen. Nachrichten dort warten und werden danach beantwortet. Bist du nicht dabei, bekommst du eine Push-Nachricht, sobald der Agent fertig ist.

**Chats finden** – oben in der Seitenleiste durchsucht „Chats durchsuchen“ Titel und Inhalte. Nach 30 Minuten ohne Nutzung startet die App mit einem neuen Chat.''',
  ),

  // ---------------------------------------------------------------------- Chat
  HelpArticle(
    id: 'attachments',
    category: 'Chat',
    icon: Icons.attach_file,
    title: 'Dateien, Fotos & Bilder',
    summary: 'PDFs, Texte, Tabellen und Bilder anhängen und auswerten lassen.',
    keywords: 'anhang pdf foto kamera bild kassenbon abschreiben vision csv json',
    body: '''Über 📎 hängst du Dateien an: PDF, TXT, MD, CSV, JSON und Bilder. Am Handy kannst du auch direkt ein **Foto aufnehmen**.

Bei Bildern schlägt Junels passende Aufträge vor: **Zusammenfassen**, **Text abschreiben**, **Termin anlegen**, **Kassenbon** auslesen.

Damit der Agent Bilder sehen kann, braucht das Modell eine Bild-Erweiterung („Vision“). Fehlt sie, bietet Junels den Download an.

Aus anderen Apps: **Teilen → Junels** (Android) bzw. Dateien aufs Dock-Symbol ziehen (Mac). Am Mac geht auch: Text oder Link markieren → Rechtsklick → **Dienste → An Junels senden**.''',
  ),
  HelpArticle(
    id: 'internet',
    category: 'Chat',
    icon: Icons.public,
    title: 'Internet-Freigabe',
    summary: 'Offline, Fragen oder Online – pro Chat einstellbar.',
    keywords: 'internet freigabe offline online fragen websuche einmal ganzer chat',
    body: '''Oben rechts im Chat zeigt der Schalter, ob der Agent ins Internet darf:

- **Offline** – keine Websuche, keine Webseiten.
- **Fragen** – vor jedem Zugriff kommt eine Rückfrage: „Nein“, „Einmal“ oder „Ganzer Chat“.
- **Online** – ohne Nachfrage für diesen Chat.

Gesendet werden nur Suchbegriffe bzw. Adressen. Das Sprachmodell läuft weiter lokal (außer du hast einen Cloud-Anbieter freigegeben, siehe „KI-Anbieter“).''',
  ),
  HelpArticle(
    id: 'browser',
    category: 'Chat',
    icon: Icons.travel_explore,
    title: 'Eingebauter Browser',
    summary: 'Der Agent öffnet Seiten, sucht, klickt und tippt – du schaust zu.',
    keywords: 'browser webseite amazon suche klicken captcha anmelden login privat',
    body: '''Sag zum Beispiel „Such auf amazon.de nach Brotdosen“ oder „Geh auf krone.at und zeig mir Sportnews“. Der Agent bedient dann den eingebauten Browser.

- Über dem Chat erscheint eine **farbige Leiste** – aufklappen zeigt die Seite live, schließen beendet den Browser für diesen Chat.
- Treffer (z. B. Produkte mit Bild und Preis) erscheinen als **Karussell**.
- Bei **Captcha oder Anmeldung** übernimmst du kurz selbst und tippst auf „Weiter“.
- **Privat anmelden**: Junels liest Eingabefelder nie aus. Passwörter und Zahlungsdaten gibst nur du ein.
- Vor Kaufen, Bestellen, Absenden oder Löschen fragt der Agent nach.''',
  ),
  HelpArticle(
    id: 'cards',
    category: 'Chat',
    icon: Icons.view_carousel_outlined,
    title: 'Ergebnis-Karten & Links',
    summary: 'Web-Treffer als wischbare Karten mit Bild, Titel und Link.',
    keywords: 'karussell karten links weitere laden mehr suchen nachrichten produkte',
    body: '''Ergebnisse aus Websuche, Webseiten, Shops und Nachrichten erscheinen als Karten mit Bild, Titel, Text und Link.

- Am Ende des Karussells lädt **„Weitere laden“** zusätzliche Treffer (bis zu 60).
- **„Mehr suchen“** startet eine neue Suche zum selben Thema.
- Links im Text werden kurz und lesbar angezeigt, Werbe-Weiterleitungen werden aufgelöst.''',
  ),
  HelpArticle(
    id: 'artifacts',
    category: 'Chat',
    icon: Icons.dashboard_outlined,
    title: 'Artefakte & Metriken',
    summary: 'Erzeugte Dokumente, Präsentationen, Diagramme und Leistungswerte.',
    keywords: 'artefakt pdf präsentation pptx diagramm tabelle code metriken tokens geschwindigkeit inspector',
    body: '''Bittet man den Agenten um ein Dokument („Mach daraus ein PDF“, „Erstelle eine Präsentation“, „Zeichne ein Diagramm“), landet das Ergebnis rechts unter **Artefakte**. Von dort öffnen, teilen oder speichern.

Unter **Metriken** siehst du, wie schnell das Modell arbeitet (Tokens pro Sekunde, Zeit bis zum ersten Wort, Context-Auslastung).

Auf großen Bildschirmen blendest du den Bereich mit dem Symbol oben rechts ein und aus, am Handy öffnet er sich von rechts.''',
  ),
  HelpArticle(
    id: 'loose-ends',
    category: 'Chat',
    icon: Icons.pending_actions_outlined,
    title: 'Liegengebliebenes aufspüren',
    summary: 'Offene Rückfragen, Vorhaben, Fehler, Termine und Mails auf einen Blick.',
    keywords: 'liegengeblieben offen unerledigt vergessen nachfassen aufgaben mails tickets',
    body: '''Frag z. B. „Was ist bei mir liegengeblieben?“ oder nutze die Vorlage *Liegengebliebenes*. Junels sammelt:

- **Rückfragen**, auf die der Agent noch auf deine Antwort wartet, und **abgebrochene Antworten**
- **Vorhaben** aus deinen Chats („muss noch …“, „bis Freitag …“)
- **Fehlgeschlagene Prozesse** und **Beobachtungen** mit Fehlern oder ungelesenen Meldungen
- **Termine** der nächsten 7 Tage, die Vorbereitung brauchen könnten
- **Unbeantwortete Mails** aus deinem Posteingang (ohne Newsletter) – dafür im Mail-Konto „Posteingang lesen“ einschalten (Einstellungen → Verbindungen → Tresor & Konten). Junels liest nur Absender, Betreff und Datum und ändert nichts im Postfach.
- **Aufgaben, Tickets, weitere Postfächer** – wenn ein passendes Werkzeug verbunden ist (MCP-Store, z. B. Gmail, Slack, Jira, Notion)

Am Ende steht eine Liste, das Dringendste zuerst, mit je einem nächsten Schritt. Tipp: Als geplante Aufgabe jeden Freitag laufen lassen.''',
  ),
  HelpArticle(
    id: 'designs',
    category: 'Chat',
    icon: Icons.palette_outlined,
    title: 'Designs & Vorlagen',
    summary: 'Präsentationen und Dokumente im passenden Look – oder nach deiner Vorlage.',
    keywords: 'folie ändern überarbeiten löschen vorschau durchblättern design vorlage template powerpoint pptx word docx excel xlsx folien farben schrift reise roter faden customer journey slidesgo',
    body: '''Der Agent wählt für Präsentationen automatisch einen Stil, der zum Thema passt (z. B. **Reise** – auch als Landschaft, Vintage oder Nacht –, Natur, Business, Technik, Bildung, Gesundheit). Eine Reise-Präsentation bekommt etwa eine Flugroute auf der Titelfolie, eine **Reiseroute** als Übersicht und unten eine Fortschrittsleiste – so entsteht ein **roter Faden**.

**Eigene Vorlagen nutzen**
- **PowerPoint anhängen** (.pptx/.potx): Folienmaster, Hintergründe, Farben und Schriften werden übernommen.
- **Word oder Excel anhängen**: Farben und Schriften des Dokuments werden übernommen.
- **Beispielbilder oder Links** (z. B. Vorlagen-Seiten wie slidesgo): Der Agent liest die Farben aus den Bildern. Für Links fragt er vorher nach der Internet-Freigabe.

Die Rückmeldung nach dem Erstellen sagt, welches Design verwendet wurde.

**Eigene Designs (z. B. Firmen-CI)**
Unter Einstellungen → Agent → *Eigene Designs* legst du Designs an – aus einer PowerPoint (inklusive Folienmaster), Word, Excel, einem Logo/Bild oder von Hand mit Farben und Schriften. Als *Standard* gilt es für alle neuen Präsentationen und PDFs; sonst nennst du es beim Namen („im Firmen-CI“).

**Gezielt ändern statt neu erstellen**
Sag z. B. „Überarbeite Folie 3: mehr zu Kulinarik“, „Lösche Folie 5“ oder „Ändere im Bericht den Abschnitt Fazit“. Der Agent ändert nur diese Stelle – Design und übrige Folien bleiben gleich. Die Nummern entsprechen PowerPoint (1 = Titelfolie).

**Vorschau**
Im Bereich *Artefakte* siehst du die Folien als kleine Bilder. Antippen öffnet sie groß zum Durchblättern (Pfeiltasten am Mac). Angehängte Office-Dateien kann der Agent außerdem lesen und als Inhaltsbasis verwenden.''',
  ),
  HelpArticle(
    id: 'approvals',
    category: 'Chat',
    icon: Icons.fact_check_outlined,
    title: 'Freigabe-Karten (E-Mail, WhatsApp)',
    summary: 'Entwürfe erscheinen als Karte – du entscheidest, ob gesendet wird.',
    keywords: 'email mail whatsapp senden entwurf freigabe karte smtp verwerfen bearbeiten',
    body: '''Bittest du den Agenten, eine E-Mail oder WhatsApp-Nachricht zu schreiben, erscheint eine Karte mit **Senden**, **Bearbeiten** und **Verwerfen**.

- Mit eingerichtetem Mail-Konto (Einstellungen → Gerät & Verbindungen → Tresor & Konten) sendet Junels direkt.
- Sonst öffnet „Senden“ deine Mail- bzw. WhatsApp-App mit dem fertigen Text.
- Im Gesprächsmodus genügt ein gesprochenes „Ja“.

Jede gesendete Nachricht steht danach unter **Aktivitäten**.''',
  ),

  // -------------------------------------------------------------------- Sprache
  HelpArticle(
    id: 'voice-input',
    category: 'Sprache',
    icon: Icons.mic_none,
    title: 'Spracheingabe',
    summary: 'Diktieren statt tippen – erkannt wird lokal.',
    open: 'settings:voice',
    keywords: 'mikrofon diktieren spracheingabe whisper canary parakeet erkennung',
    body: '''Tippe auf das Mikrofon neben dem Eingabefeld, sprich, und tippe erneut. Der Text landet im Eingabefeld (oder wird sofort gesendet, wenn das eingestellt ist).

**Spracherkennung**
- **Canary** (146 MB) – sehr schnell, ideal fürs Handy.
- **Parakeet** (464 MB) – schnell und genau, ideal am Mac.
- **Whisper** – Rückfallebene, langsamer.

Auswahl und Optionen unter Einstellungen → Sprache.''',
  ),
  HelpArticle(
    id: 'conversation',
    category: 'Sprache',
    icon: Icons.graphic_eq,
    title: 'Gesprächsmodus',
    summary: 'Freihändig sprechen – der Agent antwortet mit Stimme.',
    shot: 'conversation',
    keywords: 'gespräch freihändig name weckwort unterbrechen kreis stimme kokoro piper vorlesen',
    body: '''Starte das Gespräch über das Wellen-Symbol. Der Kreis in der Mitte zeigt den Zustand: Er pulsiert, während der Agent zuhört, denkt oder spricht.

- **Tipp auf den Kreis** = „Fertig – antworten“ bzw. Unterbrechen.
- **Name des Agenten**: In den Gesprächs-Einstellungen gibst du ihm einen Namen. Mit „Nur auf den Namen hören“ lösen Geräusche nichts mehr aus.
- Nach einer Antwort hast du **20 Sekunden** für Nachfragen ohne Namen.
- **Freigaben** (Internet, E-Mail senden) werden gesprochen gestellt und mit „Ja“ oder „Nein“ beantwortet.
- Deine Frage wird nur am Bildschirm gezeigt, nie vorgelesen.

**Stimmen**: Kokoro Martin und Victoria (sehr natürlich) sowie Piper-Stimmen – im Systemcheck unter Stimmen laden. Unter Einstellungen → Sprache kannst du probehören.

**Schneller und flüssiger**: Die Stimme wird beim Start des Gesprächs geladen, die nächsten Sätze entstehen schon, während der vorige gesprochen wird. Braucht der Agent das Internet, sagt er kurz „Moment …“. Abkürzungen, Uhrzeiten, Grad, Prozent und Euro werden ausgesprochen. Mit Bluetooth-Kopfhörern oder im Auto bleibt die Wiedergabe in voller Qualität (kein Telefonmodus).''',
  ),

  // ------------------------------------------------------------------- Automatik
  HelpArticle(
    id: 'tasks',
    category: 'Automatik',
    icon: Icons.schedule,
    title: 'Geplante Aufgaben',
    summary: 'Aufträge, die der Agent selbständig zur eingestellten Zeit erledigt.',
    shot: 'tasks',
    open: 'tasks',
    keywords: 'zeitplan täglich morgen-übersicht morning briefing termine vorbereiten folgemail push automatisch',
    body: '''Unter **Geplante Aufgaben** stehen alle Aufträge mit Zeitplan – mit Schalter, „Jetzt ausführen“ und nächstem Lauf.

**Vorlagen**
- **Morgen-Übersicht** – Termine, Wetter und Nachrichten jeden Morgen als Push-Nachricht.
- **Termine vorbereiten** (Mo–Fr 7:30) – pro Termin eine einseitige Notiz: Firma, Webseite, Fragen, Ziele.
- **Folgemail nach Terminen** – Push-Nachricht, sobald ein Termin vorbei ist.

**Eigene Aufgabe**: „Neue Aufgabe“, Text eingeben und einen Zeitplan wählen. Du kannst auch im Chat sagen: „Erinnere mich jeden Montag um 8 an …“.''',
  ),
  HelpArticle(
    id: 'flows',
    category: 'Automatik',
    icon: Icons.account_tree_outlined,
    title: 'Prozesse (Canvas)',
    summary: 'Abläufe aus Bausteinen bauen – oder per Prompt erzeugen lassen.',
    shot: 'flows',
    open: 'flows',
    keywords: 'prozess workflow canvas baustein knoten n8n automatisierung ablauf verbinden auslöser api rest mcp sso oauth google stopp fehler',
    body: '''Ein Prozess ist eine Kette von **Bausteinen**, die der Agent nacheinander ausführt – ähnlich wie bei n8n.

**Bausteine**
- **Auslöser** – manuell, nach Zeitplan oder **Beobachten** (Webseite oder Thema, bis zu minütlich).
- **Agent** – ein Auftrag an den Agenten mit allen Werkzeugen.
- **Werkzeug** – ein bestimmtes Werkzeug direkt aufrufen (Websuche, Wetter, Nachrichten …).
- **Web-API** – eine REST-Schnittstelle aufrufen (GET, POST …), optional mit **Zugang**: API-Schlüssel, Token, Benutzer/Passwort oder Anmeldung per **OAuth/SSO** (Google, Microsoft, GitHub, eigener OpenID-Anbieter). „Wert auslesen“ holt ein Feld aus der JSON-Antwort.
- **MCP-Server** – ein Tool eines verbundenen MCP-Servers, inklusive Anmeldung.
- **Bedingung** – weiter nur, wenn das vorige Ergebnis etwas enthält.
- **Benachrichtigung** – Push-Nachricht mit dem Ergebnis.
- **Notiz speichern** – Ergebnis ins Gedächtnis bzw. als Dokument.

**Bauen**: „+ Baustein“ in der Leiste unten hängt den neuen Baustein automatisch an den gewählten bzw. ans Ende der Kette. **Verbinden am Handy**: den Punkt rechts am Baustein antippen, dann den Ziel-Baustein antippen – oder im Baustein „Verbinden mit …“ wählen. Am Mac geht auch Ziehen. „Auto-verbinden“ verbindet lose Bausteine logisch von links nach rechts; ein Baustein, den du rechts neben einen anderen schiebst, wird ebenfalls verbunden. Mit {{vorher}} nutzt ein Baustein das Ergebnis des vorigen.

**Per Prompt erzeugen**: Beschreibe den Ablauf in einem Satz („Jeden Morgen Tech-News suchen, zusammenfassen und mir schicken“) – der Agent baut den Prozess.

**Ausführen**: ▶ prüft zuerst, ob alles bereit ist (Modell, Internet, Zugänge, Erreichbarkeit) und bietet Lösungen an. Während des Laufs zeigt der Canvas animiert, wo der Prozess gerade ist; **Stopp** bricht sofort ab.

**Fehler**: Bleibt ein Baustein hängen, steht dort, was schiefging, und ein Hinweis, was hilft. Du kannst ihn selbst ändern, den **Agenten beheben lassen** oder **ab hier erneut** starten – ohne die vorigen Schritte zu wiederholen.''',
  ),
  HelpArticle(
    id: 'watchlist',
    category: 'Automatik',
    icon: Icons.radar,
    title: 'Watchlist',
    summary: 'Webseiten oder Themen beobachten und bei Änderungen benachrichtigt werden.',
    shot: 'watch',
    open: 'watch',
    keywords: 'watchlist beobachten überwachen webseite thema änderung preis neu benachrichtigung schwellenwert kurs aktie unter über wochenrückblick duplikate gelesen ungelesen',
    body: '''Die Watchlist prüft regelmäßig Webseiten oder Themen und meldet sich, wenn sich etwas ändert. Sie ist Teil der **Prozesse**: Jede Beobachtung ist ein Prozess mit dem Auslöser „Beobachten“, an den du im Canvas weitere Schritte hängen kannst.

- **Webseite** – z. B. eine Produktseite, ein Blog oder eine Stellenausschreibung. Junels vergleicht den Inhalt mit dem letzten Stand.
- **Thema als Suchanfrage** – wie bei Google: "genaue Phrase", -ausschließen, site:orf.at, OR. Beispiel: "Wiener Linien" Störung -Wartung
- **Thema als Beschreibung** – in eigenen Worten („Neue Förderungen für E-Autos in Österreich, nur offizielle Stellen“). Junels macht daraus eine Suche und der Agent prüft jeden neuen Treffer, ob er wirklich passt.
- **Nur Aktuelles** – nur Meldungen der letzten 24 Stunden.
- **Intervall** – von jeder Minute bis wöchentlich. Minütlich prüft Junels, solange die App läuft; im Hintergrund lässt Android oft nur alle paar Minuten zu.
- **Jetzt testen** zeigt vor dem Speichern, was Junels findet.
- Optional fasst der Agent die Änderung zusammen und schickt eine Push-Nachricht.
- **Schwellenwert** – „Melden: wenn ein Wert unter/über … liegt“. Bei Themen holt Junels den Börsenkurs (Aktie, ETF, Index, Krypto, Währung), bei Webseiten die Zahl neben einer Beschriftung (z. B. „Preis“). Gemeldet wird nur beim Über- bzw. Unterschreiten, erst wieder nach einer Rückkehr über die Schwelle. Schnell geht's auch per Prompt: „Melde dich, wenn die Nvidia-Aktie unter 120 fällt“.
- **Wochenrückblick** – sonntags ein Absatz mit den wichtigsten Entwicklungen; wahlweise zusätzlich zu oder statt der Einzelmeldungen.
- **Doppelte Meldungen** – dieselbe Nachricht aus mehreren Quellen erscheint nur einmal („auch: finanzen.net, …“); schon Gemeldetes kommt nicht nochmal.
- **Gelesen/Neu** – im Verlauf zeigt „Neu“ nur, was seit deinem letzten Besuch dazukam. Über ⋮ markierst du einzelne Meldungen als ungelesen.

Neue Treffer sind in der Seitenleiste mit einem Punkt markiert. Beim Anlegen erlaubst du den Internetzugriff für genau diesen Eintrag.''',
  ),
  HelpArticle(
    id: 'prompts',
    category: 'Automatik',
    icon: Icons.bolt_outlined,
    title: 'Prompt-Vorlagen',
    summary: 'Häufige Aufträge speichern und mit einem Tipp starten.',
    shot: 'prompts',
    open: 'prompts',
    keywords: 'prompt vorlage speichern starten blitz',
    body: '''Speichere Aufträge, die du öfter brauchst, als Vorlage – über das ⚡-Menü im Eingabefeld („Eingabe als Prompt speichern“) oder im Chat („Speichere als Prompt …“).

Vorlagen startest du über das ⚡-Menü oder unter **Prompt-Vorlagen** in der Seitenleiste. Bekommt eine Vorlage einen Zeitplan, wird sie zur **geplanten Aufgabe**.''',
  ),

  // --------------------------------------------------------------------- Wissen
  HelpArticle(
    id: 'knowledge',
    category: 'Wissen',
    icon: Icons.local_library_outlined,
    title: 'Wissen & Gedächtnis',
    summary: 'Eigene Dokumente als Wissensbasis und Notizen, die der Agent sich merkt.',
    shot: 'knowledge',
    open: 'knowledge',
    keywords: 'wissen gedächtnis merken notizen quellen pdf ordner vorlieben personen routinen bestätigen sensibel',
    body: '''**Wissensbasis** – Füge PDFs, Texte oder ganze Ordner hinzu. Der Agent durchsucht sie bei passenden Fragen und nennt die Quelle.

**Gedächtnis** – Der Agent merkt sich Dinge, die du ihm sagst („Merk dir, dass …“). Einträge sind nach Bereichen geordnet: Vorlieben, Personen, Routinen, Projekte.

- Neue Einträge gelten erst nach deiner **Bestätigung** (abschaltbar).
- **Sensible Themen** (Gesundheit, Finanzen …) werden standardmäßig nicht gespeichert.
- Jeden Eintrag kannst du bearbeiten oder löschen.''',
  ),
  HelpArticle(
    id: 'activity',
    category: 'Wissen',
    icon: Icons.history,
    title: 'Aktivitäten',
    summary: 'Was hat der Agent getan? Alle Aktionen mit Zeitpunkt.',
    open: 'activity',
    keywords: 'aktivitäten verlauf was hat der agent getan protokoll aktionen',
    body: '''Unter **Aktivitäten** stehen alle Aktionen, die der Agent mit deiner Freigabe ausgeführt hat: gesendete E-Mails, Kalendereinträge, Dateiaktionen, Internetzugriffe, Browser-Schritte, gemerkte Notizen.

Alles bleibt lokal auf dem Gerät.''',
  ),

  // --------------------------------------------------------- Modelle & Anbieter
  HelpArticle(
    id: 'providers',
    category: 'Modelle & Anbieter',
    icon: Icons.cloud_outlined,
    title: 'KI-Anbieter: Lokal, On-Prem & Cloud',
    summary: 'Neben lokalen Modellen auch eigene Server oder Cloud-APIs nutzen.',
    shot: 'providers',
    open: 'settings:providers',
    keywords: 'api openai anthropic claude gemini mistral openrouter ollama on-prem cloud schlüssel key freigabe routing',
    body: '''Unter Einstellungen → **KI-Anbieter** bindest du weitere Modelle an:

- **On-Prem** – ein eigener Server im Firmennetz oder zu Hause (Ollama, LM Studio, vLLM oder jeder OpenAI-kompatible Server).
- **Cloud** – OpenAI, Anthropic (Claude), Google Gemini, Mistral oder OpenRouter.

API-Schlüssel liegen im **Tresor**, nie in den App-Dateien.

**Wann wird was benutzt?**
- **Nur lokal** – alles bleibt auf dem Gerät (Standard).
- **Nur On-Prem** – dein Server antwortet, nichts geht in die Cloud.
- **Nur Cloud** – der gewählte Cloud-Anbieter antwortet.
- **Lokal zuerst, Cloud nach Freigabe** – zuerst antwortet das lokale Modell bzw. dein Server. Klappt es nicht oder tippst du auf „Mit Cloud beantworten“, fragt Junels: **Nein / Einmal / Ganzer Chat**.

Welcher Anbieter geantwortet hat, steht unter jeder Antwort.''',
  ),
  HelpArticle(
    id: 'auto-model',
    category: 'Modelle & Anbieter',
    icon: Icons.alt_route,
    title: 'Automatische Modellwahl',
    summary: 'Schnelles Modell für den Alltag, starkes für komplexe Aufgaben – ohne Speicher zu verschwenden.',
    open: 'settings:models',
    keywords: 'modell wahl automatisch qwen gemma schnell stark komplex wechsel speicher vorladen ram',
    body: '''Sind zwei Sprachmodelle unterschiedlicher Größe installiert (z. B. **Qwen** klein und **Gemma** groß), wählt Junels je Anfrage:

- **Schnell** – Grüße, Wetter, Fakten, Rechnen, kurze Fragen.
- **Stark** – Analysen, Vergleiche, Code, Präsentationen und Berichte, lange Texte, angehängte Dokumente, mehrteilige Aufträge. Nachfragen bleiben beim starken Modell.
- Klappt eine Antwort mit dem schnellen Modell nicht, übernimmt automatisch das starke.

Die Einschätzung braucht kein zusätzliches Modell und kostet praktisch nichts.

**Speicher schonen**
- **Genug Arbeitsspeicher** (meist am Mac): beide bleiben geladen, der Wechsel ist sofort. Das große Modell wird nach 30 Minuten Pause freigegeben.
- **Wenig Arbeitsspeicher** (meist am Handy): es ist nur eines geladen. Erkennt Junels schon **beim Tippen** eine komplexe Anfrage, lädt es das große Modell im Voraus – meist ist es fertig, bevor du sendest. Nach ein paar Minuten Pause geht es zurück zum schnellen Modell.

Unter jeder Antwort steht, welches Modell geantwortet hat. Einstellen und Modelle selbst festlegen: Einstellungen → Lokale Modelle → Automatische Modellwahl.''',
  ),
  HelpArticle(
    id: 'agent',
    category: 'Modelle & Anbieter',
    icon: Icons.smart_toy_outlined,
    title: 'Agent-Profile & Werkzeuge',
    summary: 'Verhalten des Agenten und seine Werkzeuge einstellen.',
    open: 'settings:agent',
    keywords: 'profil system prompt werkzeuge tools temperatur schritte',
    body: '''Unter Einstellungen → **Agent & Werkzeuge**:

- **Profil** – System-Prompt, Temperatur und maximale Schritte. Mehrere Profile für unterschiedliche Aufgaben.
- **Werkzeuge** – einzeln ein- und ausschalten: Rechner, Websuche, Webseiten, Browser, Wetter, Nachrichten, Kalender, Kontakte, E-Mail, Dokumente, Diagramme, Bilder und mehr.

Werkzeuge mit Internetzugriff fragen vorher nach (je nach Internet-Schalter des Chats).''',
  ),

  // --------------------------------------------------------------- Verbindungen
  HelpArticle(
    id: 'mcp',
    category: 'Verbindungen',
    icon: Icons.hub_outlined,
    title: 'MCP-Server & Store',
    summary: 'Weitere Werkzeuge wie GitHub, Notion, Slack oder Gmail anbinden.',
    keywords: 'mcp server store github notion slack gmail atlassian oauth anmeldung',
    body: '''Über **MCP** (Model Context Protocol) bekommt der Agent zusätzliche Werkzeuge.

- **MCP-Store**: empfohlene Server (GitHub, Notion, Atlassian, Microsoft, Stripe …) und Suche im offiziellen Verzeichnis – mit einem Tipp hinzufügen.
- **Anmeldung** im Browser (OAuth); Tokens werden automatisch erneuert und liegen im Tresor.

Zu finden unter Einstellungen → Agent & Werkzeuge → MCP-Store & Server.''',
  ),
  HelpArticle(
    id: 'vault',
    category: 'Verbindungen',
    icon: Icons.lock_outline,
    title: 'Tresor & Konten',
    summary: 'Passwörter, API-Schlüssel und Anmeldungen sicher ablegen.',
    keywords: 'tresor passwort schlüssel keychain keystore mail konto smtp app-passwort',
    body: '''Der Tresor speichert Geheimnisse im **macOS-Schlüsselbund** bzw. **Android-Keystore**. Der Agent hat kein Werkzeug, um sie zu lesen – sie werden nur für die jeweilige Verbindung benutzt.

Hier liegen: Mail-Konto (SMTP mit App-Passwort), API-Schlüssel der KI-Anbieter und MCP-Anmeldungen.

Zu finden unter Einstellungen → Gerät & Verbindungen → Tresor & Konten.''',
  ),
  HelpArticle(
    id: 'sync',
    category: 'Verbindungen',
    icon: Icons.sync,
    title: 'Abgleich Mac ↔ Handy',
    summary: 'Chats, Prompts und Notizen zwischen Geräten abgleichen.',
    keywords: 'abgleich sync synchronisieren server wlan verschlüsselt',
    body: '''Junels gleicht Chats, Prompts, Aufgaben und Notizen zwischen Mac und Android ab – über deinen eigenen Server oder direkt im WLAN, **Ende-zu-Ende verschlüsselt**.

Einrichten unter Einstellungen → Gerät & Verbindungen → Abgleich.''',
  ),
  HelpArticle(
    id: 'device',
    category: 'Verbindungen',
    icon: Icons.devices_other,
    title: 'Gerät, Kalender & Dateien',
    summary: 'Heimatort, Schnellstart, Kalender, Kontakte, Ordner.',
    keywords: 'heimatort schnellstart startbildschirm dock kalender kontakte anrufen ordner dateien umbenennen verschieben',
    body: '''Unter Einstellungen → Gerät & Verbindungen → **Gerät & Automatik**:

- **Heimatort** für Wetter und Morgen-Übersicht.
- **Schnellstart**: Knöpfe auf dem Startbildschirm (Android) bzw. im Dock-Menü (Mac).
- **Widget (Android)**: „Frag Junels …“ öffnet einen neuen Chat, das Mikrofon startet ein Gespräch – lange auf den Startbildschirm drücken → Widgets → Junels.
- **Kurzbefehl (Mac)**: In der Kurzbefehle-App „URL öffnen“ mit `junels://frage?text=…` stellt sofort eine Frage, `junels://sprechen` startet ein Gespräch, `junels://neu` einen neuen Chat. Funktioniert auch aus Raycast, Alfred oder per Tastenkürzel.
- **Sicherung**: Einstellungen → App → Sicherung – alle Chats, Prozesse und Einstellungen als ZIP exportieren oder wiederherstellen (auch zum Umziehen auf ein anderes Gerät).
- **Beobachtete Ordner**: neue PDFs landen automatisch in der Wissensbasis.

Der Agent kann – jeweils mit Rückfrage – **Termine** abfragen und eintragen, **Kontakte** suchen, **anrufen** und am Mac **Dateien** suchen, umbenennen und verschieben.''',
  ),

  // ------------------------------------------------------------ App & Sicherheit
  HelpArticle(
    id: 'ai-label',
    category: 'App & Sicherheit',
    icon: Icons.auto_awesome_outlined,
    title: 'KI-Kennzeichnung',
    summary: 'Woran du erkennst, was die KI erzeugt hat – nach den EU-Vorgaben.',
    keywords: 'ki kennzeichnung ai generated eu ai act symbol hinweis fehler bild wasserzeichen transparenz',
    body: '''Junels kennzeichnet KI-Inhalte nach dem **EU AI Act** (Art. 50) mit den offiziellen EU-Symbolen:

- **Bilder**, die der Agent erzeugt, tragen klein in der Ecke unten rechts das Symbol **„AI GENERATED“** – fest im Bild, damit es auch beim Teilen oder Herunterladen sichtbar bleibt. Zusätzlich steht die Kennzeichnung maschinenlesbar in der Bilddatei.
- **Antworten** im Chat und im Gesprächsmodus haben unten das Symbol **„AI“** mit dem Hinweis „Mit KI erzeugt · KI kann Fehler machen“.
- **Dokumente und Präsentationen** (PDF, PowerPoint) haben auf jeder Seite bzw. Folie eine Fußzeile mit demselben Hinweis.

Bitte prüfe wichtige Angaben – Zahlen, Termine, Namen, rechtliche oder medizinische Aussagen – bevor du sie weitergibst.''',
  ),
  HelpArticle(
    id: 'privacy',
    category: 'App & Sicherheit',
    icon: Icons.verified_user_outlined,
    title: 'Datenschutz & Sicherheit',
    summary: 'Was bleibt auf dem Gerät, was wird gesendet?',
    keywords: 'datenschutz sicherheit privat lokal cloud passwort zahlungsdaten freigabe',
    body: '''- Das lokale Sprachmodell läuft **auf dem Gerät**. Chats, Dateien und Notizen bleiben dort.
- **Internet** nur nach Freigabe – gesendet werden nur Suchbegriffe und Adressen.
- **Cloud-Anbieter** bekommen deine Nachricht nur, wenn du sie freigibst (siehe KI-Anbieter).
- **Passwörter und Zahlungsdaten** gibst nur du ein. Der Browser liest Eingabefelder nicht aus.
- Vor Senden, Kaufen, Löschen oder Termin-Eintragen fragt der Agent nach.
- Geheimnisse liegen im Tresor des Betriebssystems.''',
  ),
  HelpArticle(
    id: 'updates',
    category: 'App & Sicherheit',
    icon: Icons.system_update_outlined,
    title: 'Updates & Protokoll',
    summary: 'Neue Versionen installieren und Fehler nachvollziehen.',
    keywords: 'update version installieren protokoll log fehler versionsverlauf',
    body: '''**Updates**: Gibt es eine neue Version, erscheint oben in der Seitenleiste ein Hinweis. Ein Tipp lädt und installiert sie – deine Modelle und Chats bleiben erhalten.

**Am Mac**: „Jetzt aktualisieren“ lädt die neue Version, öffnet das Installationsfenster und beendet Junels – eine geöffnete App kann macOS nicht ersetzen. Dann Junels auf „Programme“ ziehen, „Ersetzen“ wählen und neu starten. Löschen ist nicht nötig.

**Versionsverlauf**: steht auf derselben Seite unter „Was ist neu“ (Einstellungen → Darstellung & App → Updates & Versionsverlauf).

**Protokoll**: Unter Einstellungen → Darstellung & App → Protokoll siehst du Fehler, Lade- und Antwortzeiten. Du kannst es kopieren und teilen.''',
  ),
  HelpArticle(
    id: 'appearance',
    category: 'App & Sicherheit',
    icon: Icons.contrast,
    title: 'Darstellung & Fokus',
    summary: 'Hell, Dunkel oder System – und der Fokus-Modus.',
    open: 'settings:app',
    keywords: 'dunkel hell design theme fokus vollbild',
    body: '''Unter Einstellungen → **Darstellung & App** wählst du Hell, Dunkel oder wie das System.

Der **Fokus-Modus** (Symbol oben rechts im Chat) blendet alle Leisten aus – nur der Chat bleibt.''',
  ),
];

Future<void> openHelp(BuildContext context, {String? article}) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => HelpPage(initial: article)));

class HelpPage extends StatefulWidget {
  const HelpPage({super.key, this.initial});
  final String? initial;

  @override
  State<HelpPage> createState() => _HelpPageState();
}

class _HelpPageState extends State<HelpPage> {
  final _search = TextEditingController();
  String _q = '';
  late String? _selected = widget.initial;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Treffer nach Relevanz: Titel > Stichworte > Zusammenfassung > Text.
  List<HelpArticle> get _results {
    final words = _q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
    if (words.isEmpty) return helpArticles;
    final scored = <(HelpArticle, int)>[];
    for (final a in helpArticles) {
      var score = 0;
      var all = true;
      for (final w in words) {
        var s = 0;
        if (a.title.toLowerCase().contains(w)) s += 8;
        if (a.keywords.contains(w)) s += 5;
        if (a.summary.toLowerCase().contains(w)) s += 3;
        if (a.body.toLowerCase().contains(w)) s += 1;
        if (s == 0) all = false;
        score += s;
      }
      if (all && score > 0) scored.add((a, score));
    }
    scored.sort((x, y) => y.$2.compareTo(x.$2));
    return [for (final s in scored) s.$1];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 860;
      final results = _results;
      final list = _ArticleList(
        search: _search,
        query: _q,
        onQuery: (v) => setState(() => _q = v),
        results: results,
        selected: wide ? (_selected ?? helpArticles.first.id) : null,
        onSelect: (a) {
          if (wide) {
            setState(() => _selected = a.id);
          } else {
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Scaffold(appBar: AppBar(title: Text(a.category)), body: HelpArticleView(article: a))));
          }
        },
      );
      if (!wide) {
        if (widget.initial != null) {
          final a = helpArticles.where((x) => x.id == widget.initial).firstOrNull;
          if (a != null) return Scaffold(appBar: AppBar(title: Text(a.category)), body: HelpArticleView(article: a));
        }
        return Scaffold(appBar: AppBar(title: const Text('Hilfe')), body: list);
      }
      final article = helpArticles.firstWhere((a) => a.id == (_selected ?? helpArticles.first.id),
          orElse: () => helpArticles.first);
      final c = AppColors.of(context);
      return Scaffold(
        appBar: AppBar(title: const Text('Hilfe')),
        body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            width: 330,
            decoration: BoxDecoration(color: c.panel, border: Border(right: BorderSide(color: c.border))),
            child: list,
          ),
          Expanded(
              child: HelpArticleView(
                  key: ValueKey(article.id), article: article, onSelect: (a) => setState(() => _selected = a.id))),
        ]),
      );
    });
  }
}

class _ArticleList extends StatelessWidget {
  const _ArticleList({
    required this.search,
    required this.query,
    required this.onQuery,
    required this.results,
    required this.selected,
    required this.onSelect,
  });
  final TextEditingController search;
  final String query;
  final ValueChanged<String> onQuery;
  final List<HelpArticle> results;
  final String? selected;
  final ValueChanged<HelpArticle> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final searching = query.trim().isNotEmpty;
    Widget tile(HelpArticle a) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: ListTile(
            dense: true,
            selected: a.id == selected,
            leading: Icon(a.icon, size: 20, color: a.id == selected ? c.mint : c.muted),
            title: Text(a.title, style: const TextStyle(fontWeight: FontWeight.w500)),
            subtitle: Text(a.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => onSelect(a),
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        TextField(
          controller: search,
          onChanged: onQuery,
          autofocus: false,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: 'Hilfe durchsuchen – z. B. „Watchlist“, „Stimme“, „API“',
            suffixIcon: searching
                ? IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      search.clear();
                      onQuery('');
                    })
                : null,
          ),
        ),
        const SizedBox(height: 6),
        if (searching) ...[
          SectionLabel('${results.length} Treffer'),
          if (results.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Nichts gefunden. Versuch ein anderes Wort.', style: t.bodySmall),
            ),
          for (final a in results) tile(a),
        ] else
          for (final cat in helpCategories) ...[
            SectionLabel(cat),
            for (final a in helpArticles.where((a) => a.category == cat)) tile(a),
          ],
      ],
    );
  }
}

class HelpArticleView extends StatelessWidget {
  const HelpArticleView({super.key, required this.article, this.onSelect});
  final HelpArticle article;

  /// Breite Ansicht: verwandten Artikel daneben öffnen statt neue Seite.
  final ValueChanged<HelpArticle>? onSelect;

  void _open(BuildContext context) {
    final o = article.open;
    if (o == null) return;
    if (o == 'systemcheck') {
      openSystemCheck(context);
    } else if (o.startsWith('settings:')) {
      openSettings(context, section: o.substring(9));
    } else {
      final s = AppSection.values.where((x) => x.name == o).firstOrNull;
      if (s != null) {
        final nav = ShellNav.maybeOf(context);
        if (nav != null && nav.embedded) {
          nav.go(s);
        } else {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => pageFor(s)));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final a = article;
    final related = helpArticles.where((x) => x.category == a.category && x.id != a.id).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                StatusChip(a.category, color: c.mint, soft: c.mintSoft),
              ]),
              const SizedBox(height: 12),
              PageHeader(
                title: a.title,
                subtitle: a.summary,
                icon: a.icon,
                actions: [
                  if (a.open != null)
                    FilledButton.tonalIcon(
                      onPressed: () => _open(context),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Öffnen'),
                    ),
                ],
              ),
              if (a.shot != null) _Screenshot(name: a.shot!),
              MarkdownLite(a.body, selectable: true),
              if (related.isNotEmpty) ...[
                const SizedBox(height: 28),
                const SectionLabel('Mehr dazu', padding: EdgeInsets.fromLTRB(0, 0, 0, 8)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final r in related)
                    ActionChip(
                      avatar: Icon(r.icon, size: 16),
                      label: Text(r.title),
                      onPressed: () {
                        if (onSelect != null) {
                          onSelect!(r);
                        } else {
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => Scaffold(appBar: AppBar(title: Text(r.category)), body: HelpArticleView(article: r))));
                        }
                      },
                    ),
                ]),
              ],
              const SizedBox(height: 12),
              Text('', style: t.bodySmall),
            ]),
          ),
        ),
      ],
    );
  }
}

/// Welche Hilfe-Bilder in der App stecken (einmal gelesen).
final Future<Set<String>> _helpAssets = AssetManifest.loadFromAssetBundle(rootBundle)
    .then((m) => m.listAssets().where((a) => a.startsWith('assets/help/')).toSet())
    .catchError((_) => <String>{});

class _Screenshot extends StatelessWidget {
  const _Screenshot({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => FutureBuilder<Set<String>>(
        future: _helpAssets,
        builder: (context, snap) {
          final have = snap.data ?? const {};
          if (!have.contains('assets/help/$name.png')) return const SizedBox.shrink();
          return _frame(context);
        },
      );

  Widget _frame(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final file = 'assets/help/$name${dark ? '' : '_light'}.png';
    Widget img(String path, {ImageErrorWidgetBuilder? onError}) => Image.asset(path, fit: BoxFit.contain, errorBuilder: onError);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Ui.r),
          border: Border.all(color: c.border),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.35 : 0.08), blurRadius: 24, offset: const Offset(0, 8))],
        ),
        clipBehavior: Clip.antiAlias,
        child: GestureDetector(
          onTap: () => showDialog<void>(
            context: context,
            builder: (ctx) => Dialog(
              insetPadding: const EdgeInsets.all(16),
              clipBehavior: Clip.antiAlias,
              child: InteractiveViewer(maxScale: 4, child: img(file, onError: (_, __, ___) => img('assets/help/$name.png'))),
            ),
          ),
          // Fehlt die helle Variante, das dunkle Bild; fehlt beides, nichts.
          child: img(file,
              onError: (_, __, ___) => img('assets/help/$name.png', onError: (_, __, ___) => const SizedBox.shrink())),
        ),
      ),
    );
  }
}
