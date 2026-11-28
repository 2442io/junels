<?php
/**
 * Junels Agent-API – Logik. Speicher: Kanal-Speicher der Weiche (JUNELS_STORAGE/junels).
 */
declare(strict_types=1);

final class Api
{
    const MAX_BODY = 64 * 1024 * 1024;
    // v3: Konto-Übersicht (/konto im Browser, /status für die App), Geräte beim Abgleich

    public static function headers(): void
    {
        if (headers_sent()) return;
        header('Cache-Control: no-store');
        header('X-Content-Type-Options: nosniff');
        header('X-Frame-Options: DENY');
        header('Referrer-Policy: no-referrer');
        header('Cross-Origin-Opener-Policy: same-origin');
        header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'");
        if (!empty($_SERVER['HTTPS']) && strtolower((string)$_SERVER['HTTPS']) !== 'off') {
            header('Strict-Transport-Security: max-age=31536000');
        }
    }

    public static function json(array $data, int $code = 200): never
    {
        http_response_code($code);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        exit;
    }

    public static function fail(int $code, string $msg): never { self::json(['error' => $msg], $code); }

    /** Speicherordner (Kanal-Speicher der Weiche; ohne Weiche: ../storage neben der Version). */
    public static function storage(): string
    {
        $root = defined('JUNELS_STORAGE') ? (string)JUNELS_STORAGE : dirname(__DIR__, 2) . '/storage';
        $d = rtrim($root, '/') . '/junels';
        self::dir($d);
        return $d;
    }

    public static function dir(string $d): void
    {
        if (!is_dir($d) && !@mkdir($d, 0700, true)) self::fail(500, 'Speicher nicht beschreibbar');
        if (!is_file("$d/.htaccess")) @file_put_contents("$d/.htaccess", "Require all denied\n");
        if (!is_file("$d/index.html")) @file_put_contents("$d/index.html", '');
    }

    // ───────────────────────────── SSO ─────────────────────────────────

    public static function ssoReady(): bool { return defined('JUNELS_SSO_FILE') && is_file((string)JUNELS_SSO_FILE); }

    private static function sso(): void
    {
        if (!self::ssoReady()) self::fail(503, 'SSO ist hier nicht eingerichtet (Weiche fehlt)');
        require_once JUNELS_SSO_FILE;
        Sso::$stateDir = (string)JUNELS_SSO_STATE;
        Sso::$kitUrl = (string)JUNELS_SSO_URL;
    }

    /** Im Browser: zeigt, ob das SSO gekoppelt ist (sonst Kopplung starten). */
    public static function loginInfo(): never
    {
        self::sso();
        $u = Sso::guard((defined('JUNELS_BASE') ? (string)JUNELS_BASE : '') . '/login');
        self::page('Junels Agent-API', '<p>SSO ist verbunden. Angemeldet als <strong>' . htmlspecialchars((string)($u['name'] ?? $u['email'] ?? '')) . '</strong>.</p>'
            . '<p>In Junels: Einstellungen → Konto, Daten &amp; Abgleich → „Mit SSO anmelden“.</p>'
            . '<p><a href="' . htmlspecialchars((defined('JUNELS_BASE') ? (string)JUNELS_BASE : '') . '/konto') . '">Konto-Übersicht: Geräte, Daten, Anmeldungen →</a></p>');
    }

    /**
     * App-Anmeldung per App-Link: SSO, dann einmaliger Code an junels://sso/<code>.
     * Der Code allein nützt nichts – die App tauscht ihn unter /token nur mit ihrem geheimen Prüfwert
     * (dessen SHA-256 hier in der Adresse steht) gegen das Zugangs-Token.
     */
    public static function loginApp(string $challenge, string $here): never
    {
        self::sso();
        $u = Sso::guard($here);
        $code = bin2hex(random_bytes(24));
        self::store('codes.json', function (array $all) use ($code, $challenge, $u) {
            foreach ($all as $k => $c) if ((int)$c['t'] < time() - 600) unset($all[$k]);
            $all[hash('sha256', $code)] = ['c' => $challenge, 'sub' => (string)$u['sub'], 'name' => (string)($u['name'] ?? ''), 'email' => (string)($u['email'] ?? ''), 't' => time()];
            return $all;
        });
        $link = 'junels://sso/' . $code;
        header('Refresh: 0; url=' . $link);
        self::page('Zurück zu Junels', '<p>Angemeldet als <strong>' . htmlspecialchars((string)(($u['name'] ?? '') ?: ($u['email'] ?? ''))) . '</strong>.</p>'
            . '<p><a href="' . $link . '" style="display:inline-block;background:#c96442;color:#fff;padding:12px 20px;border-radius:10px;text-decoration:none;font-weight:600">Junels öffnen</a></p>'
            . '<p style="color:#888;font-size:14px">Öffnet sich Junels nicht von selbst, tippe auf den Knopf. Danach kannst du dieses Fenster schließen.</p>');
    }

    /** Einmal-Code + Prüfwert → Zugangs-Token. */
    public static function token(): never
    {
        $req = json_decode((string)file_get_contents('php://input', false, null, 0, 4096), true);
        $code = is_array($req) ? (string)($req['code'] ?? '') : '';
        $verifier = is_array($req) ? (string)($req['verifier'] ?? '') : '';
        if (!preg_match('/^[0-9a-f]{48}$/', $code) || strlen($verifier) < 32) self::fail(400, 'Ungültige Anmeldung');
        $hit = null;
        self::store('codes.json', function (array $all) use ($code, &$hit) {
            $k = hash('sha256', $code);
            $hit = $all[$k] ?? null;
            unset($all[$k]);   // nur einmal verwendbar
            return $all;
        });
        if (!$hit || (int)$hit['t'] < time() - 600 || !hash_equals((string)$hit['c'], hash('sha256', $verifier))) {
            self::fail(401, 'Anmeldung abgelaufen – bitte in Junels erneut „Mit SSO anmelden“');
        }
        $token = bin2hex(random_bytes(32));
        self::tokens(function (array $all) use ($token, $hit) {
            $all[hash('sha256', $token)] = ['sub' => $hit['sub'], 'name' => $hit['name'], 'email' => $hit['email'], 't' => time(), 'used' => time()];
            return $all;
        });
        self::json(['ok' => true, 'token' => $token, 'name' => $hit['name'], 'email' => $hit['email']]);
    }

    /** App-Anmeldung (ältere Apps): SSO, dann Token an die App auf diesem Gerät (127.0.0.1:<port>/sso/<token>). */
    public static function login(int $port, string $here): never
    {
        if ($port < 1024 || $port > 65535) self::fail(400, 'Ungültiger Port');
        self::sso();
        $u = Sso::guard($here);   // leitet zum SSO und kommt hierher zurück
        $token = bin2hex(random_bytes(32));
        self::tokens(function (array $all) use ($token, $u) {
            $all[hash('sha256', $token)] = ['sub' => (string)$u['sub'], 'name' => (string)($u['name'] ?? ''), 'email' => (string)($u['email'] ?? ''), 't' => time(), 'used' => time()];
            return $all;
        });
        header('Location: http://127.0.0.1:' . $port . '/sso/' . $token, true, 302);
        exit;
    }

    /** Tokens: Hash → Person. Mit $change unter Sperre ändern. */
    public static function tokens(?callable $change = null): array
    {
        return self::store('tokens.json', $change);
    }

    /** JSON-Datei im Speicher lesen und (mit $change) unter Sperre ändern. */
    public static function store(string $file, ?callable $change = null): array
    {
        $fh = fopen(self::storage() . '/' . $file, 'c+');
        if ($fh === false) self::fail(500, $file . ' nicht schreibbar');
        flock($fh, LOCK_EX);
        $all = json_decode(stream_get_contents($fh) ?: '', true) ?: [];
        if ($change) {
            $all = $change($all);
            ftruncate($fh, 0);
            rewind($fh);
            fwrite($fh, json_encode($all));
            fflush($fh);
        }
        flock($fh, LOCK_UN);
        fclose($fh);
        return $all;
    }

    public static function cleanupTokens(int $days): int
    {
        $n = 0;
        self::tokens(function (array $all) use ($days, &$n) {
            foreach ($all as $k => $t) {
                if ((int)($t['used'] ?? $t['t'] ?? 0) < time() - $days * 86400) { unset($all[$k]); $n++; }
            }
            return $all;
        });
        return $n;
    }

    // ───────────────────────────── API ─────────────────────────────────

    public static function post(string $action): never
    {
        $raw = file_get_contents('php://input', false, null, 0, self::MAX_BODY + 1);
        if ($raw === false || strlen($raw) > self::MAX_BODY) self::fail(413, 'Anfrage zu groß');
        $req = json_decode($raw, true);
        if (!is_array($req)) self::fail(400, 'kein gültiges JSON');

        $tok = (string)($req['token'] ?? '');
        $key = $tok !== '' ? hash('sha256', $tok) : '';
        $who = $key !== '' ? (self::tokens()[$key] ?? null) : null;
        if (!$who) self::fail(401, 'Bitte in Junels (neu) mit SSO anmelden');
        if ((int)($who['used'] ?? 0) < time() - 86400) {
            self::tokens(function (array $all) use ($key) { if (isset($all[$key])) $all[$key]['used'] = time(); return $all; });
        }
        $dir = self::userDir((string)$who['sub']);

        switch ($action) {
            case 'status':
                self::json(self::overview($dir, (string)$who['sub'], $key));
            case 'whoami':
                self::json(['ok' => true, 'name' => $who['name'], 'email' => $who['email']]);
            case 'logout':
                self::tokens(function (array $all) use ($key) { unset($all[$key]); return $all; });
                self::json(['ok' => true]);
            case 'wipe':
                foreach (array_merge(glob($dir . '/*.sqlite') ?: [], glob($dir . '/*.json') ?: []) as $f) @unlink($f);
                @unlink($dir . '/allowed.txt');
                self::json(['ok' => true, 'wiped' => true]);
            default:
                self::sync($dir, $req);
        }
    }

    /** Abgleich (wie junels-sync.php v1): Elemente k/t/d/b, neuester Zeitstempel gewinnt. */
    private static function sync(string $dir, array $req): never
    {
        $account = (string)($req['account'] ?? '');
        if (!preg_match('/^[0-9a-f]{64}$/', $account)) self::fail(400, 'ungültige Konto-Kennung');
        // je Person nur ein Sync-Passwort (verhindert Vermischung)
        $af = "$dir/allowed.txt";
        $cur = is_file($af) ? trim((string)file_get_contents($af)) : '';
        if ($cur === '') file_put_contents($af, $account);
        elseif ($cur !== $account) self::fail(403, 'Für dein Konto ist ein anderes Sync-Passwort hinterlegt (in der App „Daten auf dem Server löschen“, um neu zu beginnen)');

        $since = (int)($req['since'] ?? 0);
        $items = [];
        $sent = [];
        $device = is_array($req['device'] ?? null) ? $req['device'] : null;
        foreach ((is_array($req['items'] ?? null) ? $req['items'] : []) as $it) {
            if (!is_array($it)) continue;
            $k = (string)($it['k'] ?? '');
            if ($k === '' || strlen($k) > 300) continue;
            $t = (int)($it['t'] ?? 0);
            $d = !empty($it['d']) ? 1 : 0;
            $items[] = [$k, $t, $d, $d ? '' : (string)($it['b'] ?? '')];
            $sent[$k] = $t;
        }
        $out = [];
        if (!extension_loaded('pdo_sqlite')) self::fail(500, 'PHP-Erweiterung pdo_sqlite fehlt');
        $db = new PDO('sqlite:' . $dir . '/' . $account . '.sqlite');
        $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $db->setAttribute(PDO::ATTR_TIMEOUT, 30);
        $db->exec('CREATE TABLE IF NOT EXISTS items (k TEXT PRIMARY KEY, t INTEGER NOT NULL, d INTEGER NOT NULL, b TEXT NOT NULL, s INTEGER NOT NULL)');
        $db->exec('CREATE INDEX IF NOT EXISTS items_s ON items(s)');
        $db->exec('CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY, v INTEGER NOT NULL)');
        $db->exec('BEGIN IMMEDIATE');
        try {
            $seq = (int)($db->query("SELECT v FROM meta WHERE name = 'seq'")->fetchColumn() ?: 0);
            $get = $db->prepare('SELECT t FROM items WHERE k = ?');
            $put = $db->prepare('INSERT OR REPLACE INTO items (k, t, d, b, s) VALUES (?, ?, ?, ?, ?)');
            foreach ($items as [$k, $t, $d, $b]) {
                $get->execute([$k]);
                $c = $get->fetchColumn();
                if ($c === false || $t > (int)$c) { $seq++; $put->execute([$k, $t, $d, $b, $seq]); }
            }
            $db->prepare("INSERT OR REPLACE INTO meta (name, v) VALUES ('seq', ?)")->execute([$seq]);
            $q = $db->prepare('SELECT k, t, d, b, s FROM items WHERE s > ? ORDER BY s');
            $q->execute([$since]);
            while ($r = $q->fetch(PDO::FETCH_ASSOC)) {
                if (isset($sent[$r['k']]) && $sent[$r['k']] === (int)$r['t']) continue;
                $out[] = ['k' => $r['k'], 't' => (int)$r['t'], 'd' => (bool)$r['d'], 'b' => $r['b'], 's' => (int)$r['s']];
            }
            $db->exec('COMMIT');
        } catch (Throwable $e) {
            $db->exec('ROLLBACK');
            throw $e;
        }
        if ($device) self::noteDevice($dir, $device, count($items), count($out));
        self::json(['seq' => $seq, 'items' => $out]);
    }

    // ───────────────────────────── Konto-Übersicht ─────────────────────

    public static function userDir(string $sub): string
    {
        $dir = self::storage() . '/u-' . substr(hash('sha256', 'junels:' . $sub), 0, 32);
        self::dir($dir);
        return $dir;
    }

    /** Gerät beim Abgleich merken (Name, System, App-Version, letzter Abgleich) – nur Metadaten, keine Inhalte. */
    private static function noteDevice(string $dir, array $d, int $up, int $down): void
    {
        $id = preg_replace('/[^0-9a-f]/', '', strtolower((string)($d['id'] ?? '')));
        if (strlen($id) < 8) return;
        $id = substr($id, 0, 64);
        $fh = fopen("$dir/devices.json", 'c+');
        if ($fh === false) return;
        flock($fh, LOCK_EX);
        $all = json_decode(stream_get_contents($fh) ?: '', true) ?: [];
        $old = $all[$id] ?? [];
        $all[$id] = [
            'name' => mb_substr((string)($d['name'] ?? 'Gerät'), 0, 60),
            'platform' => mb_substr((string)($d['platform'] ?? ''), 0, 20),
            'app' => mb_substr((string)($d['app'] ?? ''), 0, 20),
            'first' => (int)($old['first'] ?? time()),
            'last' => time(),
            'syncs' => (int)($old['syncs'] ?? 0) + 1,
            'up' => $up,
            'down' => $down,
        ];
        ftruncate($fh, 0);
        rewind($fh);
        fwrite($fh, json_encode($all));
        fflush($fh);
        flock($fh, LOCK_UN);
        fclose($fh);
    }

    const CATEGORIES = [
        'chat' => 'Chats', 'mem' => 'Gedächtnis', 'prompt' => 'Prompts & geplante Aufgaben', 'profile' => 'Profile',
        'mcp' => 'MCP-Server', 'kb' => 'Wissensbasis', 'setup' => 'Geräte-Setups', 'design' => 'Designs', 'skill' => 'Skills',
    ];

    /** Übersicht: Geräte, Daten je Kategorie, Anmeldungen, Sync-Passwort (für /status und /konto). */
    public static function overview(string $dir, string $sub, string $currentKey = ''): array
    {
        $devices = json_decode((string)@file_get_contents("$dir/devices.json"), true) ?: [];
        uasort($devices, fn($a, $b) => ($b['last'] ?? 0) <=> ($a['last'] ?? 0));
        $cats = [];
        $total = 0;
        $last = 0;
        foreach (glob($dir . '/*.sqlite') ?: [] as $f) {
            try {
                $db = new PDO('sqlite:' . $f);
                $q = $db->query('SELECT k, t, d, length(b) AS n FROM items');
                while ($r = $q->fetch(PDO::FETCH_ASSOC)) {
                    if ((int)$r['d']) continue;
                    $p = explode(':', (string)$r['k'], 2)[0];
                    $c = &$cats[$p];
                    $c['count'] = ($c['count'] ?? 0) + 1;
                    $c['bytes'] = ($c['bytes'] ?? 0) + (int)$r['n'];
                    $c['last'] = max((int)($c['last'] ?? 0), intdiv((int)$r['t'], 1000));
                    unset($c);
                    $total += (int)$r['n'];
                    $last = max($last, intdiv((int)$r['t'], 1000));
                }
            } catch (Throwable $e) {
            }
        }
        foreach ($cats as $p => &$c) $c['label'] = self::CATEGORIES[$p] ?? $p;
        unset($c);
        $sessions = [];
        foreach (self::tokens() as $k => $t) {
            if ((string)($t['sub'] ?? '') !== $sub) continue;
            $sessions[] = ['id' => substr($k, 0, 16), 'since' => (int)($t['t'] ?? 0), 'used' => (int)($t['used'] ?? 0), 'current' => $k === $currentKey];
        }
        usort($sessions, fn($a, $b) => $b['used'] <=> $a['used']);
        $af = "$dir/allowed.txt";
        return [
            'ok' => true,
            'devices' => array_map(fn($id, $d) => ['id' => (string)$id] + $d, array_keys($devices), array_values($devices)),
            'categories' => $cats,
            'bytes' => $total,
            'lastChange' => $last,
            'passwordSince' => is_file($af) ? (int)filemtime($af) : 0,
            'sessions' => $sessions,
        ];
    }

    /** Schutz für Formulare der Konto-Seite (gegen fremde Seiten, die hierher absenden) */
    private static function csrf(string $sub): string
    {
        $f = self::storage() . '/secret.key';
        if (!is_file($f)) @file_put_contents($f, bin2hex(random_bytes(32)));
        return hash_hmac('sha256', 'konto:' . $sub, (string)@file_get_contents($f));
    }

    /** Konto-Übersicht im Browser (SSO): Geräte, Daten, Anmeldungen, Löschen. */
    public static function account(string $here): never
    {
        self::sso();
        $u = Sso::guard($here);
        $sub = (string)$u['sub'];
        date_default_timezone_set('Europe/Vienna');
        $o = self::overview(self::userDir($sub), $sub);
        $h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES);
        $when = fn(int $t) => $t ? date('d.m.Y H:i', $t) : '–';
        $size = fn(int $b) => $b >= 1048576 ? number_format($b / 1048576, 1, ',', '.') . ' MB' : number_format(max(1, (int)round($b / 1024)), 0, ',', '.') . ' KB';
        $csrf = self::csrf($sub);
        $base = defined('JUNELS_BASE') ? (string)JUNELS_BASE : '';
        $form = fn(string $action, string $label, string $cls = '', string $confirm = '') =>
            '<form method="post" action="' . $h($base . '/konto/' . $action) . '" style="display:inline">'
            . '<input type="hidden" name="csrf" value="' . $csrf . '">'
            . ($confirm ? '<label style="display:block;margin:6px 0"><input type="checkbox" name="ok" value="1" required> ' . $h($confirm) . '</label>' : '')
            . '<button class="' . $cls . '">' . $h($label) . '</button></form>';

        $b = '<p class="muted">Angemeldet als <strong>' . $h(($u['name'] ?? '') ?: ($u['email'] ?? '')) . '</strong>. '
            . 'Inhalte sind Ende-zu-Ende verschlüsselt – hier siehst du nur, <em>was</em> und <em>wie viel</em> gespeichert ist, nie den Inhalt.</p>';

        // Geräte
        $b .= '<h2>Geräte</h2>';
        if (!$o['devices']) $b .= '<p class="muted">Noch kein Gerät hat sich mit Namen gemeldet (ab Junels 1.69 sichtbar).</p>';
        foreach ($o['devices'] as $d) {
            $b .= '<div class="row"><div><strong>' . $h($d['name']) . '</strong> <span class="muted">' . $h($d['platform']) . ($d['app'] ? ' · Junels ' . $h($d['app']) : '') . '</span><br>'
                . '<span class="muted">Letzter Abgleich ' . $when((int)$d['last']) . ' · ' . (int)$d['syncs'] . ' Abgleiche · zuletzt ↑' . (int)$d['up'] . ' ↓' . (int)$d['down'] . '</span></div>'
                . $form('geraet-entfernen/' . $h($d['id']), 'Entfernen', 'small') . '</div>';
        }

        // Daten
        $b .= '<h2>Daten</h2>';
        if (!$o['categories']) {
            $b .= '<p class="muted">Keine Daten gespeichert.</p>';
        } else {
            $b .= '<table>';
            foreach ($o['categories'] as $c) {
                $b .= '<tr><td>' . $h($c['label']) . '</td><td class="r">' . (int)$c['count'] . '</td><td class="r">' . $size((int)$c['bytes']) . '</td><td class="r muted">' . $when((int)$c['last']) . '</td></tr>';
            }
            $b .= '<tr class="sum"><td>Gesamt</td><td></td><td class="r">' . $size((int)$o['bytes']) . '</td><td class="r muted">' . $when((int)$o['lastChange']) . '</td></tr></table>';
        }
        $b .= '<p class="muted">Sync-Passwort festgelegt: ' . ($o['passwordSince'] ? $when((int)$o['passwordSince']) : 'noch nicht') . '. '
            . 'Alle Geräte müssen dasselbe Sync-Passwort verwenden.</p>';

        // Anmeldungen
        $b .= '<h2>Angemeldete Apps</h2>';
        if (!$o['sessions']) $b .= '<p class="muted">Keine.</p>';
        foreach ($o['sessions'] as $s) {
            $b .= '<div class="row"><div>Anmeldung vom ' . $when((int)$s['since']) . '<br><span class="muted">zuletzt genutzt ' . $when((int)$s['used']) . '</span></div>'
                . $form('abmelden/' . $h($s['id']), 'Abmelden', 'small') . '</div>';
        }

        // Neu beginnen
        $b .= '<h2>Neu beginnen</h2><p class="muted">Löscht alle Daten dieses Kontos auf dem Server und gibt das Sync-Passwort frei '
            . '(z. B. wenn ein Gerät ein anderes Sync-Passwort hat). Daten auf deinen Geräten bleiben erhalten und werden beim nächsten Abgleich wieder hochgeladen.</p>'
            . $form('loeschen', 'Alle Daten auf dem Server löschen', 'danger', 'Ja, alles auf dem Server löschen');

        self::page('Junels – Konto', $b, true);
    }

    public static function accountAction(string $action, string $back): never
    {
        self::sso();
        $u = Sso::guard($back);
        $sub = (string)$u['sub'];
        if (!hash_equals(self::csrf($sub), (string)($_POST['csrf'] ?? ''))) self::fail(403, 'Ungültiges Formular – Seite neu laden');
        $dir = self::userDir($sub);
        if ($action === 'loeschen') {
            if (($_POST['ok'] ?? '') !== '1') self::fail(400, 'Bitte bestätigen');
            foreach (array_merge(glob($dir . '/*.sqlite') ?: [], glob($dir . '/*.json') ?: []) as $f) @unlink($f);
            @unlink($dir . '/allowed.txt');
        } elseif (str_starts_with($action, 'abmelden/')) {
            $p = substr($action, 9);
            self::tokens(function (array $all) use ($p, $sub) {
                foreach ($all as $k => $t) if (str_starts_with($k, $p) && (string)($t['sub'] ?? '') === $sub) unset($all[$k]);
                return $all;
            });
        } elseif (str_starts_with($action, 'geraet-entfernen/')) {
            $id = substr($action, 17);
            $f = "$dir/devices.json";
            $all = json_decode((string)@file_get_contents($f), true) ?: [];
            unset($all[$id]);
            @file_put_contents($f, json_encode($all));
        }
        header('Location: ' . $back, true, 303);
        exit;
    }

    public static function page(string $title, string $body, bool $wide = false): never
    {
        header('Content-Type: text/html; charset=utf-8');
        echo '<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            . '<meta name="robots" content="noindex"><title>' . htmlspecialchars($title) . '</title><style>'
            . 'body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f5f2;color:#1c1c1a;font:16px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif}'
            . 'main{max-width:' . ($wide ? '680' : '440') . 'px;width:calc(100% - 32px);margin:16px;background:#fff;border:1px solid #e3e1db;border-radius:12px;padding:28px;box-sizing:border-box}h1{font-size:22px;margin:0 0 8px}'
            . 'h2{font-size:17px;margin:24px 0 8px}.muted{color:#777;font-size:14px}.row{display:flex;gap:12px;align-items:center;justify-content:space-between;padding:10px 0;border-top:1px solid #e3e1db}'
            . 'table{width:100%;border-collapse:collapse;font-size:15px}td{padding:6px 4px;border-top:1px solid #e3e1db}.r{text-align:right}.sum td{font-weight:600}'
            . 'button{font:inherit;border:1px solid #c96442;background:#c96442;color:#fff;border-radius:8px;padding:8px 14px;cursor:pointer}'
            . 'button.small{background:transparent;color:inherit;border-color:#bbb;padding:4px 10px;font-size:14px}button.danger{background:#c0392b;border-color:#c0392b}'
            . '@media(prefers-color-scheme:dark){body{background:#141413;color:#eee}main{background:#1e1e1c;border-color:#34332f}.row,td{border-color:#34332f}.muted{color:#999}}'
            . '</style></head><body><main><h1>' . htmlspecialchars($title) . '</h1>' . $body . '</main></body></html>';
        exit;
    }
}
