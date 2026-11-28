<?php
/**
 * Junels – Webseite (agent.2442.io): alle Funktionen des Agenten. Die API liegt unter /api.
 * Reines HTML/CSS, Symbole als Inline-SVG (keine externen Dateien, keine Cookies, kein Tracking).
 */
declare(strict_types=1);

final class Site
{
    const DL_MAC = 'https://github.com/2442io/junels/releases/download/aktuell/Junels.dmg';
    const DL_ANDROID = 'https://github.com/2442io/junels/releases/download/aktuell/Junels.apk';

    /** Symbole (Pfade im 24er-Raster, Strich) */
    const ICONS = [
        'chip' => '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
        'globe' => '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
        'cursor' => '<path d="M5 3l14 7-6 2-2 6z"/>',
        'record' => '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4" fill="currentColor"/>',
        'route' => '<circle cx="6" cy="19" r="2"/><circle cx="18" cy="5" r="2"/><path d="M8 19h7a3 3 0 0 0 0-6H9a3 3 0 0 1 0-6h7"/>',
        'mic' => '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
        'doc' => '<path d="M14 3H6v18h12V7z"/><path d="M14 3v4h4M9 13h6M9 17h6"/>',
        'clock' => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
        'lock' => '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
        'sync' => '<path d="M20 11a8 8 0 0 0-14-5L4 8M4 13a8 8 0 0 0 14 5l2-2"/><path d="M4 4v4h4M20 20v-4h-4"/>',
        'spark' => '<path d="M12 3l2 5 5 2-5 2-2 5-2-5-5-2 5-2z"/>',
        'eye' => '<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
        'inbox' => '<path d="M3 13l3-8h12l3 8v6H3z"/><path d="M3 13h5l1 3h6l1-3h5"/>',
        'tag' => '<path d="M3 12V3h9l9 9-9 9z"/><circle cx="7.5" cy="7.5" r="1.5"/>',
        'shield' => '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M9 12l2 2 4-4"/>',
        'plug' => '<path d="M9 2v6M15 2v6M6 8h12v4a6 6 0 0 1-12 0zM12 18v4"/>',
        'chat' => '<path d="M4 5h16v11H9l-5 4z"/>',
        'table' => '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18M9 4v16"/>',
        'book' => '<path d="M4 4h7a3 3 0 0 1 3 3v13a2 2 0 0 0-2-2H4zM20 4h-5a3 3 0 0 0-3 3"/><path d="M20 4v14h-6"/>',
        'check' => '<path d="M5 12l5 5 9-10"/>',
        'device' => '<rect x="3" y="4" width="13" height="10" rx="1"/><path d="M1 18h17"/><rect x="18" y="8" width="5" height="11" rx="1"/>',
    ];

    private static function icon(string $name, int $size = 22): string
    {
        return '<svg width="' . $size . '" height="' . $size . '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
            . 'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' . (self::ICONS[$name] ?? '') . '</svg>';
    }

    /** Funktionen nach Bereichen: [id, [de, en] Titel, [de, en] Untertitel, [[Symbol, [de, en] Titel, [de, en] Text, neu?], …]] */
    private static function features(): array
    {
        return [
            ['verstehen', ['Verstehen & antworten', 'Understand & answer'], ['Ein KI-Agent, der auf deinem Gerät läuft – und nur nach Freigabe ins Internet geht.', 'An AI agent that runs on your device – and only goes online with your permission.'], [
                ['chip', ['Lokale KI', 'Local AI'], ['Sprachmodelle wie Gemma oder Qwen laufen direkt auf Mac und Android. Ohne Konto, ohne Cloud – auch offline.', 'Language models like Gemma or Qwen run right on your Mac and Android. No account, no cloud – even offline.']],
                ['route', ['Gerät, Cloud oder Hybrid', 'Device, cloud or hybrid'], ['Pro Chat wählbar: alles lokal, eigener On-Prem-Server oder ein Cloud-Modell – Hybrid nimmt das Große nur, wenn nötig.', 'Per chat: fully local, your own on-prem server or a cloud model – hybrid only uses the big one when needed.']],
                ['globe', ['Web-Recherche mit Quellen', 'Web research with sources'], ['Suchen, Seiten lesen, Nachrichten und Wetter – jede Antwort mit Quellen. Internet nur nach deinem Ja.', 'Search, read pages, news and weather – every answer with sources. Internet only after your yes.']],
                ['book', ['Wissensbasis & Gedächtnis', 'Knowledge & memory'], ['Eigene Dokumente durchsuchbar machen; Junels merkt sich, was du ihm sagst – und reagiert auf reine Infos einfach mit 👍.', 'Make your documents searchable; Junels remembers what you tell it – and simply reacts with 👍 to plain info.']],
            ]],
            ['web', ['Im Web erledigen', 'Get things done on the web'], ['Junels arbeitet selbstständig im eingebauten Browser – plant, führt aus, prüft jeden Schritt.', 'Junels works on its own in the built-in browser – plans, acts and checks every step.'], [
                ['cursor', ['Web-Jobs', 'Web jobs'], ['Ein Auftrag in einem Satz („Finde die 5 günstigsten E-Bikes …“): Plan, Ausführung im Browser, Prüfung nach jedem Schritt, Nachweis am Ende.', 'One sentence is enough (“Find the 5 cheapest e-bikes …”): plan, run in the browser, check after each step, proof at the end.'], true],
                ['record', ['Vormachen', 'Show me once'], ['Ablauf einmal im Browser zeigen – Junels zeichnet auf, schreibt die Anleitung und spielt es danach ab. Das Modell springt nur bei Änderungen ein.', 'Show a task once in the browser – Junels records it, writes the instructions and replays it. The model only steps in when something changes.'], true],
                ['shield', ['Begleiten bei Amtswegen', 'Help with official forms'], ['Formulare von oesterreich.gv.at, wien.gv.at & Co. gemeinsam ausfüllen – Feld für Feld erklärt; sensible Felder trägst du selbst ein.', 'Fill in government forms together – explained field by field; you enter sensitive fields yourself.']],
                ['tag', ['Preis-Scout & Inserate-Wächter', 'Price scout & listing watcher'], ['Preise auf geizhals.at, willhaben und in Shops vergleichen; nur neue Inserate melden; Belege aus Portalen sammeln.', 'Compare prices across shops and marketplaces; get notified only about new listings; collect receipts from portals.'], true],
            ]],
            ['sprechen', ['Sprechen & mitschreiben', 'Talk & transcribe'], ['Freihändig reden – auf dem Gerät erkannt und gesprochen.', 'Hands-free – recognised and spoken on your device.'], [
                ['mic', ['Gesprächsmodus', 'Conversation mode'], ['Einfach reden, Junels antwortet mit Stimme. Unterbrechen mit dem Namen, Apps per Stimme steuern („Spiel Weihnachtslieder auf Spotify“).', 'Just talk and Junels answers out loud. Interrupt by name, control apps by voice (“Play Christmas songs on Spotify”).']],
                ['record', ['Mitschrift', 'Transcription'], ['Meetings und Telefonate mitschreiben (Whisper, auf dem Gerät) – danach Zusammenfassung, Rückfragen und Protokoll als Word.', 'Transcribe meetings and calls (Whisper, on device) – then a summary, follow-up questions and minutes as Word.'], true],
            ]],
            ['erstellen', ['Erstellen', 'Create'], ['Ergebnisse so, wie du sie brauchst.', 'Results the way you need them.'], [
                ['doc', ['Word, Excel, PDF & PowerPoint', 'Word, Excel, PDF & PowerPoint'], ['Dokumente, Tabellen mit Formeln, Präsentationen und PDFs erstellen – und vorhandene Dateien bearbeiten.', 'Create documents, spreadsheets with formulas, presentations and PDFs – and edit existing files.']],
                ['table', ['Darstellung nach Wahl', 'Your choice of view'], ['Text, Karten-Karussell mit Bildern und Links, Tabelle, Checkliste, Schritte oder Diagramm – je Chat, Skill oder Ablauf.', 'Text, card carousel with images and links, table, checklist, steps or chart – per chat, skill or flow.']],
                ['spark', ['Bilder & Designs', 'Images & designs'], ['Bilder erzeugen, eigene Designs für Dokumente und Folien.', 'Generate images, use your own designs for documents and slides.']],
            ]],
            ['automatisieren', ['Automatisieren', 'Automate'], ['Was regelmäßig anfällt, erledigt Junels von selbst.', 'Whatever comes up regularly, Junels handles on its own.'], [
                ['spark', ['Skills', 'Skills'], ['Anleitungen für wiederkehrende Aufgaben, aufrufbar mit /befehl – auch mitten im Satz. Im offenen Agent-Skills-Standard, importier- und exportierbar.', 'Instructions for recurring tasks, called with /command – even mid-sentence. Open Agent Skills standard, import and export.']],
                ['clock', ['Geplante Aufgaben', 'Scheduled tasks'], ['Skills mit Zeitplan: täglich, Mo–Fr oder wöchentlich – z. B. Morgen-Übersicht oder Termine vorbereiten.', 'Skills on a schedule: daily, weekdays or weekly – e.g. a morning briefing or meeting prep.']],
                ['route', ['Abläufe', 'Flows'], ['Mehrere Schritte verbinden: suchen → zusammenfassen → als Word speichern → Push. In einem Satz beschreiben, Junels baut den Ablauf.', 'Chain steps: search → summarise → save as Word → push. Describe it in one sentence, Junels builds the flow.']],
                ['eye', ['Beobachten', 'Watch'], ['Preis, Webseite oder Thema im Blick behalten – Junels meldet sich nur bei Änderungen.', 'Keep an eye on a price, page or topic – Junels only speaks up when something changes.']],
                ['inbox', ['Ergebnisse', 'Results'], ['Alles, was von selbst läuft, gesammelt an einem Ort – als Karten mit Herkunft, Fortschritt und Nachfragen.', 'Everything that runs on its own, in one place – as cards with source, progress and follow-ups.'], true],
            ]],
            ['sicher', ['Datenschutz & Geräte', 'Privacy & devices'], ['Deine Daten gehören dir.', 'Your data belongs to you.'], [
                ['sync', ['Abgleich Mac ↔ Android', 'Sync Mac ↔ Android'], ['Chats, Skills, Wissen zwischen deinen Geräten – Ende-zu-Ende verschlüsselt, über den eigenen Server oder im WLAN.', 'Chats, skills and knowledge across your devices – end-to-end encrypted, via your own server or local Wi-Fi.']],
                ['lock', ['Datenschutz-Stufen & 2-Faktor', 'Privacy levels & 2FA'], ['Du bestimmst, was das Konto speichert. Zurücksetzen nur mit SSO und Bestätigung per E-Mail.', 'You decide what the account stores. Resets need SSO plus e-mail confirmation.'], true],
                ['shield', ['Freigaben je Website', 'Per-site permissions'], ['Ausfüllen und Absenden: frei, mit Rückfrage oder nie. Bezahlen, Passwörter und CAPTCHAs bleiben immer bei dir.', 'Filling and submitting: allowed, ask first or never. Payments, passwords and CAPTCHAs always stay with you.'], true],
                ['plug', ['MCP & Apps', 'MCP & apps'], ['Eigene MCP-Server anbinden, Apps auf dem Gerät steuern, Kalender und Mail lesen – alles mit Freigabe.', 'Connect your own MCP servers, control apps on your device, read calendar and mail – always with permission.']],
            ]],
        ];
    }

    /** Texte der Seite */
    private static function texts(string $l): array
    {
        $de = [
            'title' => 'Junels – dein KI-Agent auf dem eigenen Gerät',
            'desc' => 'Junels: der freundliche KI-Agent für Mac und Android – lokal, mit Web-Jobs, Gesprächsmodus, Mitschrift, Skills und verschlüsseltem Abgleich.',
            'nav' => ['Funktionen', "So geht's", 'Fragen', 'Download'], 'account' => 'Mein Konto',
            'pill' => 'Mitschrift, Web-Jobs &amp; Vormachen', 'new' => 'Neu',
            'h1a' => 'Dein KI-Agent,', 'h1b' => 'der für dich anpackt.',
            'lead' => 'Junels beantwortet Fragen, recherchiert, schreibt Meetings mit, füllt Formulare aus und erledigt Aufgaben im Web – direkt auf deinem Mac und Android. Privat, schnell und immer mit deinem Okay.',
            'mac' => 'Für Mac laden', 'and' => 'Für Android laden', 'notes' => ['Kostenlos', 'Kein Konto nötig', 'Läuft offline'],
            'b1' => '100 % auf dem Gerät', 'b2' => '„Hey Junels …“', 'b3' => 'Mit Quellen belegt',
            'prompts' => ['Fass mir dieses PDF in 5 Punkten zusammen', 'Finde die 5 günstigsten E-Bikes unter 2.000 €', 'Schreib das Meeting als Word-Protokoll', 'Jeden Montag 8 Uhr: Wochenübersicht', 'Füll den Antrag auf wien.gv.at mit mir aus', 'Melde neue Wohnungen auf willhaben', 'Mach daraus eine PowerPoint', 'Wie wird das Wetter am Wochenende?', 'Spiel Weihnachtslieder auf Spotify', 'Wichtig wäre im /dossier unter Personas …'],
            'stats' => [['100 %', 'offline nutzbar'], ['%n', 'Funktionen in 6 Bereichen'], ['E2E', 'verschlüsselter Abgleich'], ['0', 'Tracking, Werbung, Datenverkauf']],
            'gal_e' => 'So sieht Junels aus', 'gal_h' => 'Echte Bilder aus der App', 'gal_p' => 'Chat mit Quellen, Karten mit Bildern, Ergebnisse, Skills und Abläufe – auf Mac und Android.',
            'gal' => ['m_chat' => 'Antworten mit Quellen', 'm_cards' => 'Karten, Tabelle, Checkliste', 'm_results' => 'Ergebnisse & Web-Jobs', 'm_tasks' => 'Geplante Aufgaben', 'm_flow' => 'Abläufe', 'm_watch' => 'Beobachten', 'm_skills' => 'Skills'],
            'hl' => [
                ['Web-Jobs &amp; Vormachen', 'Sag, was erledigt werden soll. Junels klickt sich durch.', 'Ein Satz genügt: Junels plant die Schritte, arbeitet im eingebauten Browser, prüft jedes Ergebnis und zeigt dir am Ende den Nachweis.', ['Ablauf einmal vormachen – Junels schreibt die Anleitung selbst', 'Preise vergleichen, Inserate beobachten, Belege sammeln', 'Bezahlen und Passwörter bleiben immer bei dir']],
                ['Sprechen &amp; Mitschrift', 'Einfach reden. Junels hört zu und schreibt mit.', 'Im Gesprächsmodus antwortet Junels mit Stimme. Die Mitschrift hält Meetings und Telefonate fest – und macht danach eine Zusammenfassung, stellt Rückfragen und legt auf Wunsch ein Word-Protokoll ab.', ['Spracherkennung direkt auf dem Gerät', 'Apps per Stimme steuern', 'Protokoll als Word mit einem Satz']],
                ['Skills &amp; Automatisieren', 'Einmal einrichten. Läuft dann von selbst.', 'Skills sind deine Kurzbefehle – mit /befehl aufrufbar, sogar mitten im Satz. Mit Zeitplan werden sie zu geplanten Aufgaben, und alles landet gesammelt in deinen Ergebnissen.', ['Morgen-Übersicht, Firmen-Dossier, Preis-Scout &amp; mehr', 'Abläufe aus mehreren Schritten in einem Satz bauen', 'Nur melden, wenn sich etwas ändert']],
                ['Datenschutz', 'Deine Daten bleiben bei dir. Punkt.', 'Die KI läuft auf deinem Gerät. Ins Internet geht Junels nur mit deinem Ja, und der Abgleich zwischen Mac und Android ist Ende-zu-Ende verschlüsselt.', ['Freigaben je Website: frei, mit Rückfrage oder nie', 'Zurücksetzen nur mit Anmeldung und E-Mail-Bestätigung', 'Kein Tracking, keine Werbung']],
            ],
            'tr' => [['00:12', 'Wir starten den Relaunch im Februar.'], ['00:31', 'Anna übernimmt die Texte, Max das Design.'], ['Junels', 'Soll ich das Protokoll als Word ablegen?']],
            'how_e' => "So geht's", 'how_h' => 'In drei Schritten startklar',
            'steps' => [['Laden &amp; Modell wählen', 'App installieren – Junels schlägt das passende Sprachmodell für dein Gerät vor.'], ['Fragen, sprechen, beauftragen', 'Schreiben, frei reden oder mit /befehl einen Skill nutzen.'], ['Zurücklehnen', 'Aufgaben einplanen und Web-Jobs starten – die Ergebnisse kommen zu dir.']],
            'faq_e' => 'Fragen', 'faq_h' => 'Gut zu wissen',
            'faq' => [
                ['Brauche ich Internet oder ein Konto?', 'Nein. Das Sprachmodell läuft auf deinem Gerät. Internet brauchst du nur für Recherche oder Web-Jobs – und auch dann fragt Junels vorher.'],
                ['Was kostet Junels?', 'Die App ist kostenlos. Wer ein Cloud-Modell nutzen möchte, trägt dafür seinen eigenen Schlüssel ein.'],
                ['Kann Junels in meinem Namen bezahlen oder Passwörter eingeben?', 'Nein. Bezahlen, Passwörter und CAPTCHAs bleiben immer bei dir – Junels zeigt dir nur, wo du klicken musst.'],
                ['Wie kommen meine Chats auf das andere Gerät?', 'Über den Abgleich: Ende-zu-Ende verschlüsselt über deinen eigenen Server oder direkt im WLAN. Der Server sieht nur verschlüsselte Daten.'],
                ['Auf welchen Geräten läuft Junels?', 'Auf Mac (Apple Silicon) und Android. Je mehr Arbeitsspeicher, desto größere Modelle sind möglich.'],
            ],
            'end_h' => 'Bereit für deinen eigenen Agenten?', 'end_p' => 'Lade Junels kostenlos für Mac oder Android – und lass ihn heute noch die erste Aufgabe erledigen.',
            'foot' => 'KI-Agent für Mac und Android · Made in Vienna', 'shots_note' => 'Die App ist derzeit auf Deutsch.',
        ];
        if ($l !== 'en') return $de;
        return [
            'title' => 'Junels – your AI agent on your own device',
            'desc' => 'Junels: the friendly AI agent for Mac and Android – local, with web jobs, conversation mode, transcription, skills and encrypted sync.',
            'nav' => ['Features', 'How it works', 'FAQ', 'Download'], 'account' => 'My account',
            'pill' => 'Transcription, web jobs &amp; show-me-once', 'new' => 'New',
            'h1a' => 'Your AI agent', 'h1b' => 'that gets things done.',
            'lead' => 'Junels answers questions, researches, transcribes meetings, fills in forms and gets tasks done on the web – right on your Mac and Android. Private, fast and always with your okay.',
            'mac' => 'Download for Mac', 'and' => 'Download for Android', 'notes' => ['Free', 'No account needed', 'Works offline'],
            'b1' => '100 % on your device', 'b2' => '“Hey Junels …”', 'b3' => 'Backed by sources',
            'prompts' => ['Summarise this PDF in 5 bullet points', 'Find the 5 cheapest e-bikes under €2,000', 'Turn the meeting into Word minutes', 'Every Monday 8 am: weekly overview', 'Help me fill in this application form', 'Tell me about new flats on the market', 'Make a PowerPoint out of this', "What's the weather this weekend?", 'Play Christmas songs on Spotify', 'Important for /dossier under personas …'],
            'stats' => [['100 %', 'usable offline'], ['%n', 'features in 6 areas'], ['E2E', 'encrypted sync'], ['0', 'tracking, ads, data selling']],
            'gal_e' => 'See it in action', 'gal_h' => 'Real screens from the app', 'gal_p' => 'Chat with sources, cards with images, results, skills and flows – on Mac and Android.',
            'gal' => ['m_chat' => 'Answers with sources', 'm_cards' => 'Cards, tables, checklists', 'm_results' => 'Results & web jobs', 'm_tasks' => 'Scheduled tasks', 'm_flow' => 'Flows', 'm_watch' => 'Watch', 'm_skills' => 'Skills'],
            'hl' => [
                ['Web jobs &amp; show-me-once', 'Say what needs doing. Junels clicks through.', 'One sentence is enough: Junels plans the steps, works in the built-in browser, checks every result and shows you the proof at the end.', ['Show a task once – Junels writes the instructions itself', 'Compare prices, watch listings, collect receipts', 'Payments and passwords always stay with you']],
                ['Talk &amp; transcribe', 'Just talk. Junels listens and takes notes.', 'In conversation mode Junels answers out loud. Transcription captures meetings and calls – then summarises, asks follow-up questions and saves Word minutes if you like.', ['Speech recognition right on your device', 'Control apps by voice', 'Minutes as Word in one sentence']],
                ['Skills &amp; automation', 'Set it up once. It runs by itself.', 'Skills are your shortcuts – called with /command, even mid-sentence. Add a schedule and they become scheduled tasks, with everything collected in your results.', ['Morning briefing, company dossier, price scout &amp; more', 'Build multi-step flows in one sentence', 'Only notified when something changes']],
                ['Privacy', 'Your data stays with you. Period.', 'The AI runs on your device. Junels only goes online after your yes, and sync between Mac and Android is end-to-end encrypted.', ['Per-site permissions: allowed, ask first or never', 'Resets need sign-in plus e-mail confirmation', 'No tracking, no ads']],
            ],
            'tr' => [['00:12', "We'll start the relaunch in February."], ['00:31', 'Anna takes the copy, Max the design.'], ['Junels', 'Shall I save the minutes as Word?']],
            'how_e' => 'How it works', 'how_h' => 'Ready in three steps',
            'steps' => [['Download &amp; pick a model', 'Install the app – Junels suggests the right language model for your device.'], ['Ask, talk, delegate', 'Type, just talk, or use a skill with /command.'], ['Sit back', 'Schedule tasks and start web jobs – the results come to you.']],
            'faq_e' => 'FAQ', 'faq_h' => 'Good to know',
            'faq' => [
                ['Do I need internet or an account?', 'No. The language model runs on your device. You only need internet for research or web jobs – and even then Junels asks first.'],
                ['What does Junels cost?', 'The app is free. If you want to use a cloud model, you add your own key.'],
                ['Can Junels pay or enter passwords for me?', 'No. Payments, passwords and CAPTCHAs always stay with you – Junels just shows you where to click.'],
                ['How do my chats get to my other device?', 'Via sync: end-to-end encrypted through your own server or directly over Wi-Fi. The server only sees encrypted data.'],
                ['Which devices does Junels run on?', 'Mac (Apple Silicon) and Android. The more memory, the bigger the models you can run.'],
            ],
            'end_h' => 'Ready for your own agent?', 'end_p' => 'Download Junels for free for Mac or Android – and let it handle its first task today.',
            'foot' => 'AI agent for Mac and Android · Made in Vienna', 'shots_note' => 'The app is currently in German.',
        ];
    }

    /** Bild aus app/img (falls vorhanden) */
    private static function img(string $base, string $name, string $alt, string $cls = ''): string
    {
        foreach (['webp', 'jpg', 'png'] as $ext) {
            if (is_file(__DIR__ . "/img/$name.$ext")) {
                return '<img class="' . $cls . '" src="' . htmlspecialchars("$base/img/$name.$ext") . '" alt="' . htmlspecialchars($alt) . '" loading="lazy" decoding="async">';
            }
        }
        return '';
    }

    /** Liefert Bilder aus app/img aus (für /img/<name>) */
    public static function asset(string $file): never
    {
        $f = __DIR__ . '/img/' . basename($file);
        $types = ['webp' => 'image/webp', 'jpg' => 'image/jpeg', 'png' => 'image/png'];
        $ext = strtolower(pathinfo($f, PATHINFO_EXTENSION));
        if (!isset($types[$ext]) || !is_file($f)) { http_response_code(404); exit; }
        header_remove('Cache-Control');
        header('Content-Type: ' . $types[$ext]);
        header('Cache-Control: public, max-age=604800');
        header('Content-Length: ' . filesize($f));
        readfile($f);
        exit;
    }

    public static function home(string $base, string $lang = 'de'): never
    {
        $en = $lang === 'en';
        $L = self::texts($lang);
        $x = $en ? 1 : 0;
        $h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES);
        $v = (int)JUNELS_API_VERSION;
        $tones = ['verstehen' => 'mint', 'web' => 'sky', 'sprechen' => 'coral', 'erstellen' => 'sun', 'automatisieren' => 'vio', 'sicher' => 'mint'];
        $nav = ''; $sections = ''; $count = 0;
        foreach (self::features() as [$id, $title, $sub, $items]) {
            $nav .= '<a href="#' . $id . '">' . $h($title[$x]) . '</a>';
            $cards = '';
            foreach ($items as $k => $it) {
                $count++;
                $cards .= '<article class="card rv"><div class="ic t-' . $tones[$id] . '">' . self::icon($it[0]) . '</div><h3>' . $h($it[1][$x])
                    . (!empty($it[3]) ? ' <span class="new">' . $L['new'] . '</span>' : '') . '</h3><p>' . $h($it[2][$x]) . '</p></article>';
            }
            $sections .= '<section id="' . $id . '" class="feat"><div class="sh rv"><span class="eyebrow t-' . $tones[$id] . '">' . $h($title[$x]) . '</span><h2>' . $h($sub[$x]) . '</h2></div>'
                . '<div class="grid">' . $cards . '</div></section>';
        }
        $marq = '';
        foreach (array_merge($L['prompts'], $L['prompts']) as $k => $p) $marq .= '<span class="chip c' . ($k % 5) . '">' . ($en ? '“' : '„') . $h($p) . '“</span>';
        $stats = '';
        foreach ($L['stats'] as [$a, $b]) $stats .= '<div class="stat rv"><b>' . str_replace('%n', (string)$count, $a) . '</b><span>' . $h($b) . '</span></div>';
        $ic = fn($n, $s = 20) => self::icon($n, $s);
        $ticks = function (array $t) use ($ic) { $o = ''; foreach ($t as $li) $o .= '<li>' . $ic('check', 18) . ' ' . $li . '</li>'; return $o; };
        $hl = $L['hl'];
        $hlT = fn($k, $tone, $rev, $vis) => '<section class="hl' . ($rev ? ' rev' : '') . ' t-' . $tone . '"><div class="txt rv"><span class="eyebrow">' . $hl[$k][0] . '</span><h2>' . $hl[$k][1] . '</h2><p>' . $hl[$k][2] . '</p><ul class="ticks">' . $ticks($hl[$k][3]) . '</ul></div>' . $vis . '</section>';
        // Bilder: echte App-Bilder, sonst gezeichnete Vorschau
        $shotHero = self::img($base, 'm_chat', $L['gal']['m_chat'], 'shot');
        $phoneInner = $shotHero !== '' ? $shotHero : '<div class="msgs"></div>';
        $shotRes = self::img($base, 'm_results', $L['gal']['m_results']);
        $shotTasks = self::img($base, 'm_tasks', $L['gal']['m_tasks']);
        $visWeb = $shotRes !== '' ? '<div class="vis shotvis rv"><div class="ph">' . $shotRes . '</div></div>'
            : '<div class="vis rv"><div class="win"><div class="wbar"><i></i><i></i><i></i><span>geizhals.at</span></div><div class="wbody"><div class="prog"><i></i></div></div></div></div>';
        $wave = '';
        foreach ([40, 70, 55, 85, 45, 75, 35, 65, 50, 80, 40] as $k => $hh) $wave .= '<i style="--hh:' . $hh . 'px;animation-delay:' . ($k / 10) . 's"></i>';
        $lines = '';
        foreach ($L['tr'] as [$a, $b]) $lines .= '<div class="ln"><small>' . $h($a) . '</small>' . $h($b) . '</div>';
        $visTalk = '<div class="vis rv"><div class="wave">' . $wave . '</div><div class="lines">' . $lines . '</div></div>';
        $visSkills = $shotTasks !== '' ? '<div class="vis shotvis rv"><div class="ph">' . $shotTasks . '</div></div>' : '<div class="vis rv"></div>';
        $visSafe = '<div class="vis rv"><div class="devs"><div class="dev mac">' . $ic('device', 40) . '</div><div class="link"><div class="lock">' . $ic('lock', 26) . '</div></div><div class="dev and">' . $ic('device', 30) . '</div></div></div>';
        $highlights = $hlT(0, 'sky', false, $visWeb) . $hlT(1, 'coral', true, $visTalk) . $hlT(2, 'vio', false, $visSkills) . $hlT(3, 'mint', true, $visSafe);
        // Galerie
        $strip = '';
        foreach (['m_chat', 'm_cards', 'm_results', 'm_tasks', 'm_flow', 'm_watch', 'm_skills'] as $n) {
            $im = self::img($base, $n, $L['gal'][$n]);
            if ($im !== '') $strip .= '<figure class="rv"><div class="fr">' . $im . '</div><figcaption>' . $h($L['gal'][$n]) . '</figcaption></figure>';
        }
        $desk = self::img($base, 'm_desktop', 'Junels – Mac');
        $gallery = $strip === '' ? '' : '<section class="gallery" id="bilder"><span class="eyebrow t-sun">' . $h($L['gal_e']) . '</span><h2>' . $h($L['gal_h']) . '</h2><p>' . $h($L['gal_p']) . '</p>'
            . ($desk !== '' ? '<div class="mac rv"><div class="wbar"><i></i><i></i><i></i><span>Junels</span></div>' . $desk . '</div>' : '')
            . '</div><div class="strip">' . $strip . '</div><div class="wrap">' . ($en ? '<p class="small">' . $h($L['shots_note']) . '</p>' : '');
        $steps = '';
        foreach ($L['steps'] as $k => [$a, $b]) $steps .= '<div class="st rv t-' . ['mint', 'sky', 'vio'][$k] . '"><i>' . ($k + 1) . '</i><h3>' . $a . '</h3><p>' . $b . '</p></div>';
        $faq = '';
        foreach ($L['faq'] as [$q, $a]) $faq .= '<details><summary>' . $h($q) . '</summary><p>' . $h($a) . '</p></details>';
        $notes = '';
        foreach ($L['notes'] as $n) $notes .= '<span>' . $ic('check', 16) . ' ' . $h($n) . '</span>';
        [$n1, $n2, $n3, $n4] = $L['nav'];
        $mac = $h(self::DL_MAC); $and = $h(self::DL_ANDROID); $admin = $h($base . '/admin'); $api = $h($base . '/api');
        $deUrl = $h($base . '/'); $enUrl = $h($base . '/en');
        $onDe = $en ? '' : ' class="on"'; $onEn = $en ? ' class="on"' : '';
        $htmlLang = $en ? 'en' : 'de';
        $icDev = $ic('device'); $icLock = $ic('lock', 18); $icMic = $ic('mic', 18); $icGlobe = $ic('globe', 18);
        header('Content-Type: text/html; charset=utf-8');
        header('Content-Language: ' . $htmlLang);
        header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'");
        echo <<<HTML
<!doctype html><html lang="{$htmlLang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{$h($L['title'])}</title>
<meta name="description" content="{$h($L['desc'])}">
<link rel="alternate" hreflang="de" href="{$deUrl}"><link rel="alternate" hreflang="en" href="{$enUrl}">
<meta name="theme-color" content="#fffaf3">
<style>
:root{--bg:#fffaf3;--ink:#1d2433;--mut:#5d6577;--line:#ece6dc;--card:#fff;--mint:#12b886;--mint2:#e3f8f0;--sky:#3b82f6;--sky2:#e6efff;--coral:#ff6b5b;--coral2:#ffe9e5;--sun:#f5a524;--sun2:#fff3dc;--vio:#8b5cf6;--vio2:#f0eaff;--sh:0 1px 2px rgba(29,36,51,.04),0 12px 32px -12px rgba(29,36,51,.14)}
*{box-sizing:border-box}html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,Arial,sans-serif;overflow-x:hidden}
a{color:inherit}.wrap{max-width:1160px;margin:0 auto;padding:0 22px}
h1,h2,h3{letter-spacing:-.02em;line-height:1.12}
.t-mint{--c:var(--mint);--c2:var(--mint2)}.t-sky{--c:var(--sky);--c2:var(--sky2)}.t-coral{--c:var(--coral);--c2:var(--coral2)}.t-sun{--c:#d98a00;--c2:var(--sun2)}.t-vio{--c:var(--vio);--c2:var(--vio2)}
/* Kopf */
header.top{position:sticky;top:0;z-index:9;background:rgba(255,250,243,.8);backdrop-filter:saturate(1.4) blur(12px);border-bottom:1px solid transparent}
header.top .wrap{display:flex;align-items:center;gap:22px;height:66px}
.logo{display:flex;align-items:center;gap:10px;font-weight:800;font-size:21px;text-decoration:none}
.logo b{display:grid;place-items:center;width:34px;height:34px;border-radius:11px;background:linear-gradient(135deg,#12b886,#3b82f6 60%,#8b5cf6);color:#fff;font-size:18px;box-shadow:0 6px 16px -6px rgba(59,130,246,.6)}
header.top nav{display:flex;gap:22px;margin-left:auto;font-size:15px;font-weight:500}header.top nav a{text-decoration:none;color:var(--mut)}header.top nav a:hover{color:var(--ink)}
.btn{display:inline-flex;align-items:center;gap:9px;padding:14px 22px;border-radius:14px;font-weight:650;text-decoration:none;border:1px solid var(--line);background:#fff;transition:transform .15s,box-shadow .15s}
.btn:hover{transform:translateY(-2px);box-shadow:var(--sh)}.btn.p{background:var(--ink);color:#fff;border-color:var(--ink)}.btn.sm{padding:8px 15px;font-size:15px;border-radius:11px}
/* Hero */
.hero{position:relative;padding:72px 0 40px}
.blob{position:absolute;border-radius:50%;filter:blur(60px);opacity:.55;z-index:-1;animation:drift 16s ease-in-out infinite alternate}
.b1{width:420px;height:420px;background:#bff0dd;left:-120px;top:-40px}.b2{width:380px;height:380px;background:#d9e6ff;right:-80px;top:40px;animation-delay:-5s}.b3{width:300px;height:300px;background:#ffe0d6;left:40%;top:320px;animation-delay:-9s}
@keyframes drift{to{transform:translate(40px,30px) scale(1.08)}}
.hgrid{display:grid;grid-template-columns:1.05fr .95fr;gap:48px;align-items:center}
.pill{display:inline-flex;align-items:center;gap:8px;padding:6px 14px 6px 8px;background:#fff;border:1px solid var(--line);border-radius:999px;font-size:14px;font-weight:600;box-shadow:var(--sh)}
.pill i{font-style:normal;background:var(--mint);color:#fff;border-radius:999px;padding:2px 9px;font-size:12px}
.hero h1{font-size:clamp(40px,6vw,70px);margin:20px 0 18px;font-weight:800}
.grad{background:linear-gradient(90deg,#12b886,#3b82f6,#8b5cf6,#ff6b5b);background-size:300% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;animation:shine 8s linear infinite}
@keyframes shine{to{background-position:300% 0}}
.lead{font-size:20px;color:var(--mut);margin:0 0 30px;max-width:560px}
.cta{display:flex;gap:12px;flex-wrap:wrap}.note{color:var(--mut);font-size:14px;margin-top:14px;display:flex;gap:16px;flex-wrap:wrap}.note span{display:inline-flex;gap:6px;align-items:center}.note svg{color:var(--mint)}
/* Handy-Mockup */
.stage{position:relative;height:600px}
.phone{position:absolute;right:60px;top:0;width:300px;height:590px;border-radius:44px;background:#1d2433;padding:12px;box-shadow:0 40px 80px -30px rgba(29,36,51,.45);animation:float 7s ease-in-out infinite}
@keyframes float{50%{transform:translateY(-12px)}}
.screen{height:100%;border-radius:34px;background:#f7f8fb;overflow:hidden;display:flex;flex-direction:column}
.sbar{display:flex;align-items:center;gap:8px;padding:18px 16px 10px;background:#fff;border-bottom:1px solid #eef0f4;font-weight:700;font-size:14px}.sbar b{width:24px;height:24px;border-radius:8px;background:linear-gradient(135deg,#12b886,#3b82f6);display:inline-block}
.sbar small{margin-left:auto;font-weight:600;color:var(--mint);font-size:11px;background:var(--mint2);padding:2px 8px;border-radius:99px}
.msgs{flex:1;padding:14px 12px;display:flex;flex-direction:column;gap:9px;font-size:13px;line-height:1.4}
.m{opacity:0;transform:translateY(10px);animation:pop .5s cubic-bezier(.2,.8,.2,1.2) forwards}
@keyframes pop{to{opacity:1;transform:none}}
.u{align-self:flex-end;background:#1d2433;color:#fff;padding:9px 12px;border-radius:16px 16px 4px 16px;max-width:85%}
.a{background:#fff;border:1px solid #eef0f4;padding:9px 12px;border-radius:16px 16px 16px 4px;max-width:92%}
.step{display:flex;gap:7px;align-items:center;color:var(--mut);font-size:12px}.step svg{color:var(--mint);flex:none}
.cards{display:flex;gap:8px;overflow:hidden}.mc{flex:none;width:118px;background:#fff;border:1px solid #eef0f4;border-radius:12px;overflow:hidden;font-size:11px}
.mc .im{height:62px}.mc div{padding:6px 8px}.mc strong{display:block;font-size:12px}.mc em{font-style:normal;color:var(--mint);font-weight:700}
.im1{background:linear-gradient(135deg,#c8f1e2,#7fd8b9)}.im2{background:linear-gradient(135deg,#dbe7ff,#93b4fb)}.im3{background:linear-gradient(135deg,#ffe1d9,#ffa894)}
.dots{display:inline-flex;gap:4px;padding:10px 12px;background:#fff;border:1px solid #eef0f4;border-radius:14px;align-self:flex-start}
.dots i{width:6px;height:6px;border-radius:50%;background:#aab;animation:blink 1.2s infinite}.dots i:nth-child(2){animation-delay:.2s}.dots i:nth-child(3){animation-delay:.4s}
@keyframes blink{50%{opacity:.25;transform:translateY(-2px)}}
.compose{margin:0 10px 12px;background:#fff;border:1px solid #eef0f4;border-radius:16px;padding:10px 12px;font-size:12px;color:#99a;display:flex;align-items:center;gap:8px}.compose span{margin-left:auto;width:26px;height:26px;border-radius:50%;background:var(--ink);display:grid;place-items:center;color:#fff}
.badge{position:absolute;background:#fff;border:1px solid var(--line);border-radius:16px;padding:10px 14px;box-shadow:var(--sh);font-size:14px;font-weight:650;display:flex;gap:10px;align-items:center;animation:float 6s ease-in-out infinite}
.badge .ic{width:34px;height:34px;margin:0;border-radius:10px}
.bd1{left:0;top:90px;animation-delay:-2s}.bd2{right:0;top:330px;animation-delay:-4s}.bd3{left:30px;bottom:40px}
/* Lauftext */
.marquee{margin:36px 0 10px;overflow:hidden;mask-image:linear-gradient(90deg,transparent,#000 10%,#000 90%,transparent)}
.track{display:flex;gap:12px;width:max-content;animation:run 60s linear infinite}.marquee:hover .track{animation-play-state:paused}
@keyframes run{to{transform:translateX(-50%)}}
.chip{white-space:nowrap;padding:10px 16px;border-radius:999px;background:#fff;border:1px solid var(--line);font-size:15px;color:var(--mut)}
.chip.c0{background:var(--mint2)}.chip.c1{background:var(--sky2)}.chip.c2{background:var(--coral2)}.chip.c3{background:var(--sun2)}.chip.c4{background:var(--vio2)}
/* Zahlen */
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:44px 0 0}
.stat{background:#fff;border:1px solid var(--line);border-radius:20px;padding:22px;box-shadow:var(--sh)}.stat b{display:block;font-size:34px;font-weight:800;letter-spacing:-.03em}.stat span{color:var(--mut);font-size:14px}
/* Highlights */
.hl{display:grid;grid-template-columns:1fr 1fr;gap:56px;align-items:center;padding:90px 0 10px}
.hl.rev .txt{order:2}
.eyebrow{display:inline-block;font-size:13px;font-weight:750;text-transform:uppercase;letter-spacing:.08em;color:var(--c);background:var(--c2);padding:5px 12px;border-radius:999px}
.hl h2{font-size:clamp(30px,4vw,44px);margin:16px 0 14px;font-weight:800}.hl p{color:var(--mut);font-size:18px;margin:0 0 18px}
.ticks{list-style:none;padding:0;margin:0;display:grid;gap:10px}.ticks li{display:flex;gap:10px;align-items:flex-start}.ticks svg{flex:none;color:var(--c);margin-top:3px}
.vis{position:relative;border-radius:28px;padding:28px;min-height:340px;background:var(--c2);overflow:hidden}
.win{background:#fff;border-radius:16px;box-shadow:var(--sh);overflow:hidden}
.wbar{display:flex;gap:6px;align-items:center;padding:10px 12px;border-bottom:1px solid #eef0f4}.wbar i{width:10px;height:10px;border-radius:50%;background:#ffb4a8}.wbar i+i{background:#ffd88a}.wbar i+i+i{background:#9ee6c6}
.wbar span{margin-left:10px;flex:1;background:#f3f4f7;border-radius:8px;padding:4px 10px;font-size:12px;color:var(--mut)}
.wbody{padding:16px;display:grid;gap:10px;font-size:14px}
.row{display:flex;gap:10px;align-items:center;padding:10px 12px;border:1px solid #eef0f4;border-radius:12px}.row b{margin-left:auto;color:var(--sky)}
.prog{height:8px;border-radius:9px;background:#eef0f4;overflow:hidden}.prog i{display:block;height:100%;width:0;background:linear-gradient(90deg,var(--sky),var(--vio));border-radius:9px;animation:fill 4s ease-in-out infinite}
@keyframes fill{0%{width:5%}70%,100%{width:100%}}
.cursor{position:absolute;width:26px;height:26px;color:var(--ink);animation:move 6s ease-in-out infinite;left:60%;top:55%}
@keyframes move{0%,100%{transform:translate(0,0)}30%{transform:translate(-120px,-60px)}60%{transform:translate(-40px,40px)}}
.wave{display:flex;gap:5px;align-items:center;height:90px;justify-content:center}
.wave i{width:7px;border-radius:9px;background:var(--coral);animation:wv 1.1s ease-in-out infinite}
@keyframes wv{0%,100%{height:14px}50%{height:var(--hh,70px)}}
.lines{display:grid;gap:8px;margin-top:16px}.ln{background:#fff;border-radius:12px;padding:10px 14px;font-size:14px;box-shadow:var(--sh)}.ln small{color:var(--coral);font-weight:700;margin-right:8px}
.input{background:#fff;border-radius:16px;padding:14px 16px;box-shadow:var(--sh);font-size:15px}.input mark{background:var(--vio2);color:var(--vio);font-weight:700;border-radius:6px;padding:1px 5px}
.sugg{display:flex;gap:8px;margin:12px 0 18px;flex-wrap:wrap}.sugg span{background:#fff;border:1px solid #e4dcff;border-radius:999px;padding:6px 12px;font-size:13px;color:var(--vio);font-weight:600}
.sched{display:grid;gap:10px}.sc{background:#fff;border-radius:14px;padding:12px 14px;display:flex;gap:12px;align-items:center;box-shadow:var(--sh);font-size:14px}.sc .ic{margin:0;width:36px;height:36px;border-radius:10px}.sc small{display:block;color:var(--mut)}
.sc em{margin-left:auto;font-style:normal;font-size:12px;font-weight:700;color:var(--mint);background:var(--mint2);padding:3px 9px;border-radius:99px}
.devs{display:flex;justify-content:space-between;align-items:center;height:260px;padding:0 10px}
.dev{background:#fff;border-radius:18px;box-shadow:var(--sh);display:grid;place-items:center;color:var(--mint)}.dev.mac{width:150px;height:100px}.dev.and{width:70px;height:130px;border-radius:16px}
.link{flex:1;height:4px;margin:0 14px;background:repeating-linear-gradient(90deg,var(--mint) 0 10px,transparent 10px 20px);background-size:40px 4px;animation:dash 1s linear infinite;position:relative}
@keyframes dash{to{background-position:40px 0}}
.lock{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:58px;height:58px;border-radius:50%;background:#fff;box-shadow:var(--sh);display:grid;place-items:center;color:var(--mint)}
/* Funktionsgitter */
.anchors{position:sticky;top:66px;z-index:8;background:rgba(255,250,243,.9);backdrop-filter:blur(10px);margin-top:90px;border-top:1px solid var(--line);border-bottom:1px solid var(--line)}
.anchors .wrap{display:flex;gap:8px;overflow-x:auto;padding:12px 22px;scrollbar-width:none}.anchors a{white-space:nowrap;text-decoration:none;font-size:14px;font-weight:600;padding:7px 14px;border-radius:999px;color:var(--mut);background:#fff;border:1px solid var(--line)}.anchors a:hover{color:var(--ink)}
.feat{padding:60px 0 0;scroll-margin-top:140px}.sh h2{font-size:clamp(24px,3vw,32px);margin:14px 0 24px;max-width:760px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:16px}
.card{background:#fff;border:1px solid var(--line);border-radius:22px;padding:24px;transition:transform .2s,box-shadow .2s}.card:hover{transform:translateY(-4px);box-shadow:var(--sh)}
.ic{width:48px;height:48px;border-radius:14px;display:grid;place-items:center;background:var(--c2);color:var(--c);margin-bottom:16px}
.card h3{font-size:18px;margin:0 0 8px}.card p{margin:0;color:var(--mut);font-size:15.5px}
.new{font-size:11px;font-weight:800;color:#fff;background:var(--coral);border-radius:7px;padding:2px 7px;vertical-align:middle;margin-left:4px}
/* So geht's */
.how{padding:100px 0 0;text-align:center}.how h2{font-size:clamp(30px,4vw,44px);margin:14px 0 36px}
.steps{display:grid;grid-template-columns:repeat(3,1fr);gap:18px;text-align:left}.st{background:#fff;border:1px solid var(--line);border-radius:22px;padding:26px;position:relative}
.st i{font-style:normal;display:grid;place-items:center;width:40px;height:40px;border-radius:12px;background:var(--c2);color:var(--c);font-weight:800;font-size:18px;margin-bottom:14px}
.st h3{margin:0 0 8px}.st p{margin:0;color:var(--mut)}
/* FAQ */
.faq{max-width:780px;margin:100px auto 0}.faq h2{text-align:center;font-size:clamp(28px,4vw,40px);margin:14px 0 26px}
details{background:#fff;border:1px solid var(--line);border-radius:16px;padding:18px 22px;margin-bottom:10px}summary{cursor:pointer;font-weight:650;list-style:none;display:flex;justify-content:space-between;gap:16px}summary::after{content:"+";color:var(--mint);font-size:22px;line-height:1}details[open] summary::after{content:"–"}
details p{color:var(--mut);margin:12px 0 0}
/* Abschluss */
.end{position:relative;overflow:hidden;margin:100px 0;padding:64px 28px;text-align:center;border-radius:32px;color:#fff;background:linear-gradient(135deg,#12b886,#3b82f6 55%,#8b5cf6)}
.end h2{font-size:clamp(30px,4.5vw,48px);margin:0 0 12px}.end p{opacity:.9;margin:0 auto 28px;max-width:560px;font-size:18px}.end .btn{border:0}.end .btn.p{background:#fff;color:var(--ink)}.end .btn:not(.p){background:rgba(255,255,255,.18);color:#fff}
.end .ring{position:absolute;border:2px solid rgba(255,255,255,.25);border-radius:50%;animation:pulse 6s ease-out infinite}.r1{width:300px;height:300px;left:-80px;top:-80px}.r2{width:420px;height:420px;right:-140px;bottom:-200px;animation-delay:-3s}
@keyframes pulse{50%{transform:scale(1.1);opacity:.5}}
footer{padding:10px 0 50px;color:var(--mut);font-size:14px}footer .wrap{display:flex;gap:24px;flex-wrap:wrap;justify-content:space-between}
/* Einblenden beim Scrollen */
@supports (animation-timeline: view()){.rv{animation:rise both cubic-bezier(.2,.7,.2,1);animation-timeline:view();animation-range:entry 0% entry 60%}}
@keyframes rise{from{opacity:0;transform:translateY(28px)}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}.m{opacity:1;transform:none}}
@media(max-width:900px){.hgrid,.hl{grid-template-columns:1fr}.hl.rev .txt{order:0}.stage{height:560px}.phone{left:50%;right:auto;margin-left:-150px}.bd1{left:-6px}.bd2{right:-6px}.stats{grid-template-columns:repeat(2,1fr)}.steps{grid-template-columns:1fr}header.top nav{display:none}header.top .btn{margin-left:auto}.hl{padding-top:70px;gap:30px}}

.lang{display:flex;gap:2px;background:#fff;border:1px solid var(--line);border-radius:10px;padding:3px;font-size:13px;font-weight:700}.lang a{text-decoration:none;padding:4px 8px;border-radius:7px;color:var(--mut)}.lang a.on{background:var(--ink);color:#fff}
.screen img.shot{width:100%;height:100%;object-fit:cover;object-position:top;display:block}
.vis.shotvis{padding:28px 28px 0;display:flex;justify-content:center;align-items:flex-end}
.vis .ph{width:280px;border-radius:30px 30px 0 0;border:10px solid #1d2433;border-bottom:0;overflow:hidden;box-shadow:0 30px 60px -30px rgba(29,36,51,.5);background:#fff}.vis .ph img{display:block;width:100%;height:440px;object-fit:cover;object-position:top}
.gallery{padding:100px 0 0;text-align:center}.gallery h2{font-size:clamp(30px,4vw,44px);margin:14px 0 10px}.gallery>p{color:var(--mut);margin:0 auto 32px;max-width:640px;font-size:18px}
.mac{max-width:1000px;margin:0 auto 34px;border-radius:16px;overflow:hidden;background:#fff;box-shadow:0 40px 80px -40px rgba(29,36,51,.45);border:1px solid var(--line)}.mac img{display:block;width:100%}
.strip{display:flex;gap:20px;overflow-x:auto;padding:10px 22px 26px;scroll-snap-type:x mandatory;scrollbar-width:thin}
.strip figure{flex:none;width:230px;margin:0;scroll-snap-align:center}.strip .fr{border-radius:28px;border:8px solid #1d2433;overflow:hidden;background:#fff;box-shadow:var(--sh);transition:transform .25s}.strip figure:hover .fr{transform:translateY(-6px) rotate(-1deg)}
.strip img{display:block;width:100%;height:470px;object-fit:cover;object-position:top}.strip figcaption{margin-top:12px;font-weight:650;font-size:15px}
.small{color:var(--mut);font-size:13px}
</style></head><body>
<header class="top"><div class="wrap">
<a class="logo" href="{$deUrl}"><b>J</b>Junels</a>
<nav><a href="#funktionen">{$n1}</a><a href="#wie">{$n2}</a><a href="#faq">{$n3}</a><a href="#download">{$n4}</a></nav>
<div class="lang"><a href="{$deUrl}"{$onDe}>DE</a><a href="{$enUrl}"{$onEn}>EN</a></div>
<a class="btn sm" href="{$admin}">{$L['account']}</a>
</div></header>

<main>
<section class="hero"><div class="blob b1"></div><div class="blob b2"></div><div class="blob b3"></div>
<div class="wrap hgrid">
<div>
<span class="pill"><i>{$L['new']}</i> {$L['pill']}</span>
<h1>{$L['h1a']}<br><span class="grad">{$L['h1b']}</span></h1>
<p class="lead">{$L['lead']}</p>
<div class="cta"><a class="btn p" href="{$mac}">{$icDev} {$L['mac']}</a><a class="btn" href="{$and}">{$icDev} {$L['and']}</a></div>
<div class="note">{$notes}</div>
</div>
<div class="stage">
<div class="phone"><div class="screen">{$phoneInner}</div></div>
<div class="badge bd1"><div class="ic t-mint">{$icLock}</div>{$L['b1']}</div>
<div class="badge bd2"><div class="ic t-coral">{$icMic}</div>{$L['b2']}</div>
<div class="badge bd3"><div class="ic t-sky">{$icGlobe}</div>{$L['b3']}</div>
</div>
</div>
<div class="marquee"><div class="track">{$marq}</div></div>
<div class="wrap"><div class="stats">{$stats}</div></div>
</section>

<div class="wrap" id="funktionen">
{$highlights}
{$gallery}
</div>

<div class="anchors"><div class="wrap">{$nav}</div></div>
<div class="wrap">
{$sections}

<section class="how" id="wie"><span class="eyebrow t-sky">{$L['how_e']}</span><h2>{$L['how_h']}</h2>
<div class="steps">{$steps}</div></section>

<section class="faq" id="faq"><div style="text-align:center"><span class="eyebrow t-coral">{$L['faq_e']}</span></div><h2>{$L['faq_h']}</h2>
{$faq}
</section>

<section class="end" id="download"><div class="ring r1"></div><div class="ring r2"></div><h2>{$L['end_h']}</h2><p>{$L['end_p']}</p>
<div class="cta" style="justify-content:center"><a class="btn p" href="{$mac}">{$L['mac']}</a><a class="btn" href="{$and}">{$L['and']}</a></div></section>
</div>
</main>

<footer><div class="wrap">
<div><strong style="color:var(--ink)">Junels</strong> · {$L['foot']}</div>
<div><a href="{$deUrl}">Deutsch</a> · <a href="{$enUrl}">English</a> · <a href="{$admin}">{$L['account']}</a> · <a href="{$api}">API</a> · v{$v}</div>
</div></footer>
</body></html>
HTML;
        exit;
    }

    /** Übersicht der API im Browser */
    public static function api(string $base): never
    {
        $rows = [
            ['GET', '/api', 'Info (JSON): Version, SSO an/aus'],
            ['GET', '/api/login', 'Anmelde-Seite (SSO-Status)'],
            ['GET', '/api/login/app/<prüfwert>', 'App-Anmeldung per SSO → junels://sso/<code>'],
            ['POST', '/api/token', 'Einmal-Code + Prüfwert → Zugangs-Token'],
            ['POST', '/api/sync', 'Abgleich (verschlüsselte Elemente)'],
            ['POST', '/api/status', 'Konto-Übersicht (JSON)'],
            ['POST', '/api/whoami', 'Name und E-Mail zum Token'],
            ['POST', '/api/logout', 'Token ungültig machen'],
            ['POST', '/api/wipe', 'Zurücksetzen anfordern (Bestätigung per E-Mail)'],
            ['GET', '/admin', 'Konto im Browser: Geräte, Daten, Anmeldungen, Sync-Passwort zurücksetzen'],
        ];
        $b = '<p class="muted">Speicher und Anmeldung für die Junels-App. Inhalte sind Ende-zu-Ende verschlüsselt. '
            . 'Die bisherigen Adressen ohne <code>/api</code> funktionieren weiter.</p><table>';
        foreach ($rows as [$m, $p, $d]) {
            $b .= '<tr><td><strong>' . $m . '</strong></td><td><code>' . htmlspecialchars($p) . '</code></td><td class="muted">' . htmlspecialchars($d) . '</td></tr>';
        }
        $b .= '</table><p><a href="' . htmlspecialchars($base . '/') . '">← Zur Webseite</a></p>';
        Api::page('Junels API v' . (int)JUNELS_API_VERSION, $b, true);
    }
}
