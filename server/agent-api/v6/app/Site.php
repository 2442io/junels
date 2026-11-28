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
        'device' => '<rect x="3" y="4" width="13" height="10" rx="1"/><path d="M1 18h17"/><rect x="18" y="8" width="5" height="11" rx="1"/>',
    ];

    private static function icon(string $name, int $size = 22): string
    {
        return '<svg width="' . $size . '" height="' . $size . '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
            . 'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' . (self::ICONS[$name] ?? '') . '</svg>';
    }

    /** Funktionen nach Bereichen: [id, Titel, Untertitel, [[Symbol, Titel, Text, neu?], …]] */
    private static function features(): array
    {
        return [
            ['verstehen', 'Verstehen & antworten', 'Ein KI-Agent, der auf deinem Gerät läuft – und nur nach Freigabe ins Internet geht.', [
                ['chip', 'Lokale KI', 'Sprachmodelle wie Gemma oder Qwen laufen direkt auf Mac und Android. Ohne Konto, ohne Cloud – auch offline.'],
                ['route', 'Gerät, Cloud oder Hybrid', 'Pro Chat wählbar: alles lokal, eigener On-Prem-Server oder ein Cloud-Modell – Hybrid nimmt das Große nur, wenn nötig.'],
                ['globe', 'Web-Recherche mit Quellen', 'Suchen, Seiten lesen, Nachrichten und Wetter – jede Antwort mit Quellen. Internet nur nach deinem Ja.'],
                ['book', 'Wissensbasis & Gedächtnis', 'Eigene Dokumente durchsuchbar machen; Junels merkt sich, was du ihm sagst – und reagiert auf reine Infos einfach mit 👍.'],
            ]],
            ['web', 'Im Web erledigen', 'Junels arbeitet selbstständig im eingebauten Browser – plant, führt aus, prüft jeden Schritt.', [
                ['cursor', 'Web-Jobs', 'Ein Auftrag in einem Satz („Finde die 5 günstigsten E-Bikes …“): Plan, Ausführung im Browser, Prüfung nach jedem Schritt, Nachweis am Ende.', true],
                ['record', 'Vormachen', 'Ablauf einmal im Browser zeigen – Junels zeichnet auf, schreibt die Anleitung und spielt es danach ab. Das Modell springt nur bei Änderungen ein.', true],
                ['shield', 'Begleiten bei Amtswegen', 'Formulare von oesterreich.gv.at, wien.gv.at & Co. gemeinsam ausfüllen – Feld für Feld erklärt; sensible Felder trägst du selbst ein.'],
                ['tag', 'Preis-Scout & Inserate-Wächter', 'Preise auf geizhals.at, willhaben und in Shops vergleichen; nur neue Inserate melden; Belege aus Portalen sammeln.', true],
            ]],
            ['sprechen', 'Sprechen & mitschreiben', 'Freihändig reden – auf dem Gerät erkannt und gesprochen.', [
                ['mic', 'Gesprächsmodus', 'Einfach reden, Junels antwortet mit Stimme. Unterbrechen mit dem Namen, Apps per Stimme steuern („Spiel Weihnachtslieder auf Spotify“).'],
                ['record', 'Mitschrift', 'Meetings und Telefonate mitschreiben (Whisper, auf dem Gerät) – danach Zusammenfassung, Rückfragen und Protokoll als Word.', true],
            ]],
            ['erstellen', 'Erstellen', 'Ergebnisse so, wie du sie brauchst.', [
                ['doc', 'Word, Excel, PDF & PowerPoint', 'Dokumente, Tabellen mit Formeln, Präsentationen und PDFs erstellen – und vorhandene Dateien bearbeiten.'],
                ['table', 'Darstellung nach Wahl', 'Text, Karten-Karussell mit Bildern und Links, Tabelle, Checkliste, Schritte oder Diagramm – je Chat, Skill oder Ablauf.'],
                ['spark', 'Bilder & Designs', 'Bilder erzeugen, eigene Designs für Dokumente und Folien.'],
            ]],
            ['automatisieren', 'Automatisieren', 'Was regelmäßig anfällt, erledigt Junels von selbst.', [
                ['spark', 'Skills', 'Anleitungen für wiederkehrende Aufgaben, aufrufbar mit /befehl – auch mitten im Satz. Im offenen Agent-Skills-Standard, importier- und exportierbar.'],
                ['clock', 'Geplante Aufgaben', 'Skills mit Zeitplan: täglich, Mo–Fr oder wöchentlich – z. B. Morgen-Übersicht oder Termine vorbereiten.'],
                ['route', 'Abläufe', 'Mehrere Schritte verbinden: suchen → zusammenfassen → als Word speichern → Push. In einem Satz beschreiben, Junels baut den Ablauf.'],
                ['eye', 'Beobachten', 'Preis, Webseite oder Thema im Blick behalten – Junels meldet sich nur bei Änderungen.'],
                ['inbox', 'Ergebnisse', 'Alles, was von selbst läuft, gesammelt an einem Ort – als Karten mit Herkunft, Fortschritt und Nachfragen.', true],
            ]],
            ['sicher', 'Datenschutz & Geräte', 'Deine Daten gehören dir.', [
                ['sync', 'Abgleich Mac ↔ Android', 'Chats, Skills, Wissen zwischen deinen Geräten – Ende-zu-Ende verschlüsselt, über den eigenen Server oder im WLAN.'],
                ['lock', 'Datenschutz-Stufen & 2-Faktor', 'Du bestimmst, was das Konto speichert. Zurücksetzen nur mit SSO und Bestätigung per E-Mail.', true],
                ['shield', 'Freigaben je Website', 'Ausfüllen und Absenden: frei, mit Rückfrage oder nie. Bezahlen, Passwörter und CAPTCHAs bleiben immer bei dir.', true],
                ['plug', 'MCP & Apps', 'Eigene MCP-Server anbinden, Apps auf dem Gerät steuern, Kalender und Mail lesen – alles mit Freigabe.'],
            ]],
        ];
    }

    public static function home(string $base): never
    {
        $h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES);
        $v = (int)JUNELS_API_VERSION;
        $nav = '';
        $sections = '';
        $count = 0;
        foreach (self::features() as [$id, $title, $sub, $items]) {
            $nav .= '<a href="#' . $id . '">' . $h($title) . '</a>';
            $cards = '';
            foreach ($items as $it) {
                $count++;
                $cards .= '<article class="card"><div class="ic">' . self::icon($it[0]) . '</div><h3>' . $h($it[1])
                    . (!empty($it[3]) ? ' <span class="new">Neu</span>' : '') . '</h3><p>' . $h($it[2]) . '</p></article>';
            }
            $sections .= '<section id="' . $id . '" class="feat"><div class="sh"><h2>' . $h($title) . '</h2><p>' . $h($sub) . '</p></div>'
                . '<div class="grid">' . $cards . '</div></section>';
        }
        $mac = $h(self::DL_MAC);
        $and = $h(self::DL_ANDROID);
        $admin = $h($base . '/admin');
        $api = $h($base . '/api');
        header('Content-Type: text/html; charset=utf-8');
        echo <<<HTML
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Junels – dein KI-Agent auf dem eigenen Gerät</title>
<meta name="description" content="Junels: KI-Agent für Mac und Android – lokal, mit Web-Jobs, Gesprächsmodus, Mitschrift, Skills und Ende-zu-Ende-verschlüsseltem Abgleich.">
<meta name="theme-color" content="#0b0d10">
<style>
:root{--bg:#0b0d10;--panel:#14171c;--line:#23272f;--txt:#eceef1;--mut:#9aa1ad;--acc:#4fd1a1;--acc2:#c96442;--vio:#a78bfa}
*{box-sizing:border-box}html{scroll-behavior:smooth}
body{margin:0;background:var(--bg);color:var(--txt);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,Arial,sans-serif}
a{color:inherit}.wrap{max-width:1120px;margin:0 auto;padding:0 20px}
header.top{position:sticky;top:0;z-index:5;background:rgba(11,13,16,.85);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
header.top .wrap{display:flex;align-items:center;gap:20px;height:60px}
.logo{display:flex;align-items:center;gap:10px;font-weight:700;font-size:19px;text-decoration:none}
.logo b{display:grid;place-items:center;width:30px;height:30px;border-radius:9px;background:linear-gradient(135deg,var(--acc),#2a9d8f);color:#05110c;font-size:16px}
header.top nav{display:flex;gap:18px;margin-left:auto;font-size:14px}header.top nav a{text-decoration:none;color:var(--mut)}header.top nav a:hover{color:var(--txt)}
.btn{display:inline-flex;align-items:center;gap:8px;padding:12px 20px;border-radius:12px;font-weight:600;text-decoration:none;border:1px solid var(--line)}
.btn.p{background:var(--acc);color:#05110c;border-color:var(--acc)}.btn.s{background:var(--panel)}.btn.sm{padding:7px 14px;font-size:14px}
.hero{padding:84px 0 40px;text-align:center}
.hero h1{font-size:clamp(36px,6vw,64px);line-height:1.05;letter-spacing:-.03em;margin:0 0 18px}
.hero h1 span{background:linear-gradient(90deg,var(--acc),var(--vio));-webkit-background-clip:text;background-clip:text;color:transparent}
.hero p.lead{max-width:680px;margin:0 auto 28px;color:var(--mut);font-size:19px}
.cta{display:flex;gap:12px;justify-content:center;flex-wrap:wrap}.note{color:var(--mut);font-size:13px;margin-top:12px}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:48px auto 0;max-width:900px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:18px}.stat b{display:block;font-size:30px;letter-spacing:-.02em}.stat span{color:var(--mut);font-size:13px}
.anchors{position:sticky;top:60px;z-index:4;background:var(--bg);border-bottom:1px solid var(--line);margin-top:56px}
.anchors .wrap{display:flex;gap:8px;overflow-x:auto;padding:10px 20px}.anchors a{white-space:nowrap;text-decoration:none;font-size:14px;padding:6px 12px;border:1px solid var(--line);border-radius:999px;color:var(--mut)}.anchors a:hover{color:var(--txt);border-color:var(--acc)}
.feat{padding:56px 0 8px;scroll-margin-top:120px}.sh h2{font-size:30px;margin:0 0 6px;letter-spacing:-.02em}.sh p{margin:0 0 22px;color:var(--mut)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:14px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:20px;transition:border-color .2s,transform .2s}.card:hover{border-color:#3a414d;transform:translateY(-2px)}
.card .ic{width:42px;height:42px;border-radius:12px;display:grid;place-items:center;background:rgba(79,209,161,.12);color:var(--acc);margin-bottom:14px}
.card h3{font-size:17px;margin:0 0 6px}.card p{margin:0;color:var(--mut);font-size:15px}
.new{font-size:11px;font-weight:700;color:#05110c;background:var(--vio);border-radius:6px;padding:2px 6px;vertical-align:middle;margin-left:4px}
.how{padding:72px 0 16px}.steps{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}.step{border:1px solid var(--line);border-radius:16px;padding:22px}
.step i{font-style:normal;display:inline-grid;place-items:center;width:30px;height:30px;border-radius:50%;background:var(--acc);color:#05110c;font-weight:700;margin-bottom:10px}
.step h3{margin:0 0 6px}.step p{margin:0;color:var(--mut)}
.end{margin:80px 0;padding:48px 24px;text-align:center;border-radius:24px;background:radial-gradient(circle at 30% 0,rgba(79,209,161,.18),transparent 60%),var(--panel);border:1px solid var(--line)}
.end h2{font-size:32px;margin:0 0 10px}.end p{color:var(--mut);margin:0 0 24px}
footer{border-top:1px solid var(--line);padding:32px 0 48px;color:var(--mut);font-size:14px}footer .wrap{display:flex;gap:24px;flex-wrap:wrap;justify-content:space-between}footer a{color:var(--mut)}
@media(max-width:760px){header.top nav{display:none}header.top .btn{margin-left:auto}.stats{grid-template-columns:repeat(2,1fr)}.steps{grid-template-columns:1fr}.hero{padding-top:56px}}
</style></head><body>
<header class="top"><div class="wrap">
<a class="logo" href="#"><b>J</b>Junels</a>
<nav><a href="#verstehen">Funktionen</a><a href="#wie">So geht's</a><a href="#sicher">Datenschutz</a><a href="#download">Download</a></nav>
<a class="btn s sm" href="{$admin}">Mein Konto</a>
</div></header>

<main>
<section class="hero"><div class="wrap">
<h1>Dein KI-Agent.<br><span>Auf deinem Gerät.</span></h1>
<p class="lead">Junels beantwortet, recherchiert, schreibt mit, füllt Formulare aus und erledigt Aufgaben im Web – lokal auf Mac und Android, mit dir als Chef über jede Freigabe.</p>
<div class="cta"><a class="btn p" href="{$mac}">Für Mac laden</a><a class="btn s" href="{$and}">Für Android laden</a></div>
<p class="note">Kostenlos · kein Konto nötig · das Modell läuft auf dem Gerät</p>
<div class="stats">
<div class="stat"><b>100 %</b><span>offline nutzbar</span></div>
<div class="stat"><b>{$count}</b><span>Funktionen in 6 Bereichen</span></div>
<div class="stat"><b>E2E</b><span>verschlüsselter Abgleich</span></div>
<div class="stat"><b>0</b><span>Tracking, Werbung, Datenverkauf</span></div>
</div>
</div></section>

<div class="anchors"><div class="wrap">{$nav}</div></div>
<div class="wrap">
{$sections}

<section class="how" id="wie"><div class="sh"><h2>So geht's</h2><p>In drei Schritten zum eigenen Agenten.</p></div>
<div class="steps">
<div class="step"><i>1</i><h3>Laden & Modell wählen</h3><p>App installieren, ein passendes Sprachmodell für dein Gerät herunterladen – Junels schlägt eines vor.</p></div>
<div class="step"><i>2</i><h3>Fragen, sprechen, beauftragen</h3><p>Im Chat schreiben, frei reden oder mit /befehl einen Skill nutzen – auch mitten im Satz.</p></div>
<div class="step"><i>3</i><h3>Von selbst erledigen lassen</h3><p>Aufgaben einplanen, Web-Jobs starten, Abläufe bauen – Ergebnisse kommen gesammelt zu dir.</p></div>
</div></section>

<section class="end" id="download"><h2>Bereit für deinen eigenen Agenten?</h2><p>Lade Junels für Mac oder Android. Deine Daten bleiben bei dir.</p>
<div class="cta"><a class="btn p" href="{$mac}">Für Mac laden</a><a class="btn s" href="{$and}">Für Android laden</a></div></section>
</div>
</main>

<footer><div class="wrap">
<div><strong style="color:var(--txt)">Junels</strong> – KI-Agent für Mac und Android · Made in Vienna</div>
<div><a href="{$admin}">Mein Konto</a> · <a href="{$api}">API</a> · Version {$v}</div>
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
