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
        $tones = ['verstehen' => 'mint', 'web' => 'sky', 'sprechen' => 'coral', 'erstellen' => 'sun', 'automatisieren' => 'vio', 'sicher' => 'mint'];
        $nav = ''; $sections = ''; $count = 0;
        foreach (self::features() as [$id, $title, $sub, $items]) {
            $nav .= '<a href="#' . $id . '">' . $h($title) . '</a>';
            $cards = '';
            foreach ($items as $k => $it) {
                $count++;
                $cards .= '<article class="card rv" style="--d:' . ($k * 70) . 'ms"><div class="ic t-' . $tones[$id] . '">' . self::icon($it[0]) . '</div><h3>' . $h($it[1])
                    . (!empty($it[3]) ? ' <span class="new">Neu</span>' : '') . '</h3><p>' . $h($it[2]) . '</p></article>';
            }
            $sections .= '<section id="' . $id . '" class="feat"><div class="sh rv"><span class="eyebrow t-' . $tones[$id] . '">' . $h($title) . '</span><h2>' . $h($sub) . '</h2></div>'
                . '<div class="grid">' . $cards . '</div></section>';
        }
        $prompts = ['Fass mir dieses PDF in 5 Punkten zusammen', 'Finde die 5 günstigsten E-Bikes unter 2.000 €', 'Schreib das Meeting als Word-Protokoll',
            'Jeden Montag 8 Uhr: Wochenübersicht', 'Füll den Antrag auf wien.gv.at mit mir aus', 'Melde neue Wohnungen auf willhaben', 'Mach daraus eine PowerPoint',
            'Wie wird das Wetter am Wochenende?', 'Spiel Weihnachtslieder auf Spotify', 'Wichtig wäre im /dossier unter Personas …'];
        $marq = '';
        foreach (array_merge($prompts, $prompts) as $k => $p) $marq .= '<span class="chip c' . ($k % 5) . '">„' . $h($p) . '“</span>';
        $mac = $h(self::DL_MAC); $and = $h(self::DL_ANDROID); $admin = $h($base . '/admin'); $api = $h($base . '/api');
        $ic = fn($n, $s = 20) => self::icon($n, $s);
        header('Content-Type: text/html; charset=utf-8');
        header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:; frame-ancestors 'none'");
        echo <<<HTML
<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Junels – dein KI-Agent auf dem eigenen Gerät</title>
<meta name="description" content="Junels: der freundliche KI-Agent für Mac und Android – lokal, mit Web-Jobs, Gesprächsmodus, Mitschrift, Skills und verschlüsseltem Abgleich.">
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
</style></head><body>
<header class="top"><div class="wrap">
<a class="logo" href="#"><b>J</b>Junels</a>
<nav><a href="#funktionen">Funktionen</a><a href="#wie">So geht's</a><a href="#faq">Fragen</a><a href="#download">Download</a></nav>
<a class="btn sm" href="{$admin}">Mein Konto</a>
</div></header>

<main>
<section class="hero"><div class="blob b1"></div><div class="blob b2"></div><div class="blob b3"></div>
<div class="wrap hgrid">
<div>
<span class="pill"><i>Neu</i> Mitschrift, Web-Jobs &amp; Vormachen</span>
<h1>Dein KI-Agent,<br><span class="grad">der für dich anpackt.</span></h1>
<p class="lead">Junels beantwortet Fragen, recherchiert, schreibt Meetings mit, füllt Formulare aus und erledigt Aufgaben im Web – direkt auf deinem Mac und Android. Privat, schnell und immer mit deinem Okay.</p>
<div class="cta"><a class="btn p" href="{$mac}">{$ic('device')} Für Mac laden</a><a class="btn" href="{$and}">{$ic('device')} Für Android laden</a></div>
<div class="note"><span>{$ic('check',16)} Kostenlos</span><span>{$ic('check',16)} Kein Konto nötig</span><span>{$ic('check',16)} Läuft offline</span></div>
</div>
<div class="stage">
<div class="phone"><div class="screen">
<div class="sbar"><b></b>Junels<small>● auf dem Gerät</small></div>
<div class="msgs">
<div class="m u" style="animation-delay:.4s">Finde die 3 günstigsten E-Bikes unter 2.000 €</div>
<div class="m a" style="animation-delay:1.3s"><div class="step">{$ic('check',14)} geizhals.at durchsucht</div><div class="step">{$ic('check',14)} 3 Shops verglichen</div><div class="step">{$ic('check',14)} Preise geprüft</div></div>
<div class="m a" style="animation-delay:2.4s">Hier sind deine Top 3 – alle lieferbar:</div>
<div class="m cards" style="animation-delay:3s"><div class="mc"><div class="im im1"></div><div><strong>City E1</strong><em>1.499 €</em></div></div><div class="mc"><div class="im im2"></div><div><strong>Urban 7</strong><em>1.689 €</em></div></div><div class="mc"><div class="im im3"></div><div><strong>Trek Go</strong><em>1.899 €</em></div></div></div>
<div class="m dots" style="animation-delay:3.8s"><i></i><i></i><i></i></div>
</div>
<div class="compose">Frag Junels oder tippe /…<span>{$ic('mic',14)}</span></div>
</div></div>
<div class="badge bd1"><div class="ic t-mint">{$ic('lock',18)}</div>100 % auf dem Gerät</div>
<div class="badge bd2"><div class="ic t-coral">{$ic('mic',18)}</div>„Hey Junels …“</div>
<div class="badge bd3"><div class="ic t-sky">{$ic('globe',18)}</div>Mit Quellen belegt</div>
</div>
</div>
<div class="marquee"><div class="track">{$marq}</div></div>
<div class="wrap"><div class="stats">
<div class="stat rv"><b>100 %</b><span>offline nutzbar</span></div>
<div class="stat rv"><b>{$count}</b><span>Funktionen in 6 Bereichen</span></div>
<div class="stat rv"><b>E2E</b><span>verschlüsselter Abgleich</span></div>
<div class="stat rv"><b>0</b><span>Tracking, Werbung, Datenverkauf</span></div>
</div></div>
</section>

<div class="wrap" id="funktionen">
<section class="hl t-sky"><div class="txt rv"><span class="eyebrow">Web-Jobs &amp; Vormachen</span><h2>Sag, was erledigt werden soll. Junels klickt sich durch.</h2>
<p>Ein Satz genügt: Junels plant die Schritte, arbeitet im eingebauten Browser, prüft jedes Ergebnis und zeigt dir am Ende den Nachweis.</p>
<ul class="ticks"><li>{$ic('check',18)} Ablauf einmal vormachen – Junels schreibt die Anleitung selbst</li><li>{$ic('check',18)} Preise vergleichen, Inserate beobachten, Belege sammeln</li><li>{$ic('check',18)} Bezahlen und Passwörter bleiben immer bei dir</li></ul></div>
<div class="vis rv"><div class="win"><div class="wbar"><i></i><i></i><i></i><span>geizhals.at/e-bikes</span></div><div class="wbody">
<div class="prog"><i></i></div>
<div class="row">{$ic('tag',18)} City E1 – Händler A<b>1.499 €</b></div><div class="row">{$ic('tag',18)} Urban 7 – Händler B<b>1.689 €</b></div><div class="row">{$ic('tag',18)} Trek Go – Händler C<b>1.899 €</b></div>
</div></div><div class="cursor">{$ic('cursor',26)}</div></div></section>

<section class="hl rev t-coral"><div class="txt rv"><span class="eyebrow">Sprechen &amp; Mitschrift</span><h2>Einfach reden. Junels hört zu und schreibt mit.</h2>
<p>Im Gesprächsmodus antwortet Junels mit Stimme. Die Mitschrift hält Meetings und Telefonate fest – und macht danach eine Zusammenfassung, stellt Rückfragen und legt auf Wunsch ein Word-Protokoll ab.</p>
<ul class="ticks"><li>{$ic('check',18)} Spracherkennung direkt auf dem Gerät</li><li>{$ic('check',18)} Apps per Stimme steuern</li><li>{$ic('check',18)} Protokoll als Word mit einem Satz</li></ul></div>
<div class="vis rv"><div class="wave"><i style="--hh:40px"></i><i style="--hh:70px;animation-delay:.1s"></i><i style="--hh:55px;animation-delay:.2s"></i><i style="--hh:85px;animation-delay:.3s"></i><i style="--hh:45px;animation-delay:.4s"></i><i style="--hh:75px;animation-delay:.5s"></i><i style="--hh:35px;animation-delay:.6s"></i><i style="--hh:65px;animation-delay:.7s"></i><i style="--hh:50px;animation-delay:.8s"></i><i style="--hh:80px;animation-delay:.9s"></i><i style="--hh:40px;animation-delay:1s"></i></div>
<div class="lines"><div class="ln"><small>00:12</small>Wir starten den Relaunch im Februar.</div><div class="ln"><small>00:31</small>Anna übernimmt die Texte, Max das Design.</div><div class="ln"><small>Junels</small>Soll ich das Protokoll als Word ablegen?</div></div></div></section>

<section class="hl t-vio"><div class="txt rv"><span class="eyebrow">Skills &amp; Automatisieren</span><h2>Einmal einrichten. Läuft dann von selbst.</h2>
<p>Skills sind deine Kurzbefehle – mit /befehl aufrufbar, sogar mitten im Satz. Mit Zeitplan werden sie zu geplanten Aufgaben, und alles landet gesammelt in deinen Ergebnissen.</p>
<ul class="ticks"><li>{$ic('check',18)} Morgen-Übersicht, Firmen-Dossier, Preis-Scout &amp; mehr</li><li>{$ic('check',18)} Abläufe aus mehreren Schritten in einem Satz bauen</li><li>{$ic('check',18)} Nur melden, wenn sich etwas ändert</li></ul></div>
<div class="vis rv"><div class="input">Wichtig wäre im <mark>/dossier</mark> unter Personas …</div><div class="sugg"><span>/dossier</span><span>/preis</span><span>/mitschrift</span><span>/morgen</span></div>
<div class="sched"><div class="sc"><div class="ic t-sun">{$ic('clock',18)}</div><div><strong>Morgen-Übersicht</strong><small>Mo–Fr · 07:30</small></div><em>bereit</em></div><div class="sc"><div class="ic t-sky">{$ic('eye',18)}</div><div><strong>Wohnungen auf willhaben</strong><small>stündlich beobachten</small></div><em>2 neu</em></div></div></div></section>

<section class="hl rev t-mint"><div class="txt rv"><span class="eyebrow">Datenschutz</span><h2>Deine Daten bleiben bei dir. Punkt.</h2>
<p>Die KI läuft auf deinem Gerät. Ins Internet geht Junels nur mit deinem Ja, und der Abgleich zwischen Mac und Android ist Ende-zu-Ende verschlüsselt.</p>
<ul class="ticks"><li>{$ic('check',18)} Freigaben je Website: frei, mit Rückfrage oder nie</li><li>{$ic('check',18)} Zurücksetzen nur mit Anmeldung und E-Mail-Bestätigung</li><li>{$ic('check',18)} Kein Tracking, keine Werbung</li></ul></div>
<div class="vis rv"><div class="devs"><div class="dev mac">{$ic('device',40)}</div><div class="link"><div class="lock">{$ic('lock',26)}</div></div><div class="dev and">{$ic('device',30)}</div></div></div></section>
</div>

<div class="anchors"><div class="wrap">{$nav}</div></div>
<div class="wrap">
{$sections}

<section class="how" id="wie"><span class="eyebrow t-sky">So geht's</span><h2>In drei Schritten startklar</h2>
<div class="steps">
<div class="st rv t-mint"><i>1</i><h3>Laden &amp; Modell wählen</h3><p>App installieren – Junels schlägt das passende Sprachmodell für dein Gerät vor.</p></div>
<div class="st rv t-sky" style="--d:80ms"><i>2</i><h3>Fragen, sprechen, beauftragen</h3><p>Schreiben, frei reden oder mit /befehl einen Skill nutzen.</p></div>
<div class="st rv t-vio" style="--d:160ms"><i>3</i><h3>Zurücklehnen</h3><p>Aufgaben einplanen und Web-Jobs starten – die Ergebnisse kommen zu dir.</p></div>
</div></section>

<section class="faq" id="faq"><div style="text-align:center"><span class="eyebrow t-coral">Fragen</span></div><h2>Gut zu wissen</h2>
<details><summary>Brauche ich Internet oder ein Konto?</summary><p>Nein. Das Sprachmodell läuft auf deinem Gerät. Internet brauchst du nur für Recherche oder Web-Jobs – und auch dann fragt Junels vorher.</p></details>
<details><summary>Was kostet Junels?</summary><p>Die App ist kostenlos. Wer ein Cloud-Modell nutzen möchte, trägt dafür seinen eigenen Schlüssel ein.</p></details>
<details><summary>Kann Junels in meinem Namen bezahlen oder Passwörter eingeben?</summary><p>Nein. Bezahlen, Passwörter und CAPTCHAs bleiben immer bei dir – Junels zeigt dir nur, wo du klicken musst.</p></details>
<details><summary>Wie kommen meine Chats auf das andere Gerät?</summary><p>Über den Abgleich: Ende-zu-Ende verschlüsselt über deinen eigenen Server oder direkt im WLAN. Der Server sieht nur verschlüsselte Daten.</p></details>
<details><summary>Auf welchen Geräten läuft Junels?</summary><p>Auf Mac (Apple Silicon) und Android. Je mehr Arbeitsspeicher, desto größere Modelle sind möglich.</p></details>
</section>

<section class="end" id="download"><div class="ring r1"></div><div class="ring r2"></div><h2>Bereit für deinen eigenen Agenten?</h2><p>Lade Junels kostenlos für Mac oder Android – und lass ihn heute noch die erste Aufgabe erledigen.</p>
<div class="cta" style="justify-content:center"><a class="btn p" href="{$mac}">Für Mac laden</a><a class="btn" href="{$and}">Für Android laden</a></div></section>
</div>
</main>

<footer><div class="wrap">
<div><strong style="color:var(--ink)">Junels</strong> · KI-Agent für Mac und Android · Made in Vienna</div>
<div><a href="{$admin}">Mein Konto</a> · <a href="{$api}">API</a> · v{$v}</div>
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
