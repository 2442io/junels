<?php
/**
 * Junels Agent-API – Logik. Speicher: Kanal-Speicher der Weiche (JUNELS_STORAGE/junels).
 */
declare(strict_types=1);

final class Api
{
    const MAX_BODY = 64 * 1024 * 1024;
    // v3: Konto-Übersicht (/admin im Browser, /status für die App), Geräte beim Abgleich
    // v5: Sync-Passwort zurücksetzen nur mit SSO + Bestätigungslink per E-Mail; 'epoch' im Abgleich

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

    /** Startseite im Browser */
    public static function home(): never
    {
        $base = htmlspecialchars(defined('JUNELS_BASE') ? (string)JUNELS_BASE : '');
        $btn = 'display:inline-block;background:#c96442;color:#fff;padding:12px 20px;border-radius:10px;text-decoration:none;font-weight:600;margin:4px 0';
        self::page('Junels', '<p>Speicher und Anmeldung für die Junels-App – deine Daten sind Ende-zu-Ende verschlüsselt.</p>'
            . '<p><a style="' . $btn . '" href="' . $base . '/admin">Mein Konto: Geräte &amp; Daten</a></p>'
            . '<p class="muted">Anmeldung per SSO. In der App: Einstellungen → Konto, Datenschutz &amp; Abgleich.</p>'
            . '<p class="muted">Version ' . (int)JUNELS_API_VERSION . ' · <a href="' . $base . '/login">SSO-Status</a></p>');
    }

    /** Im Browser: zeigt, ob das SSO gekoppelt ist (sonst Kopplung starten). */
    public static function loginInfo(): never
    {
        self::sso();
        $u = Sso::guard((defined('JUNELS_BASE') ? (string)JUNELS_BASE : '') . '/login');
        self::page('Junels Agent-API', '<p>SSO ist verbunden. Angemeldet als <strong>' . htmlspecialchars((string)($u['name'] ?? $u['email'] ?? '')) . '</strong>.</p>'
            . '<p>In Junels: Einstellungen → Konto, Daten &amp; Abgleich → „Mit SSO anmelden“.</p>'
            . '<p><a href="' . htmlspecialchars((defined('JUNELS_BASE') ? (string)JUNELS_BASE : '') . '/admin') . '">Konto-Übersicht: Geräte, Daten, Anmeldungen →</a></p>');
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
                // Zurücksetzen nur mit zweitem Faktor: Bestätigungslink per E-Mail (plus SSO-Anmeldung beim Öffnen)
                $mail = self::startReset((string)$who['sub'], (string)($who['email'] ?? ''), (string)($who['name'] ?? ''), 'App');
                self::json(['ok' => true, 'pending' => true, 'email' => self::mask($mail)]);
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
        // Kennung dieses Datenbestands: ändert sich nach dem Zurücksetzen → die App lädt dann alles neu hoch
        $db->exec("INSERT OR IGNORE INTO meta (name, v) VALUES ('epoch', " . time() . ")");
        $epoch = (int)$db->query("SELECT v FROM meta WHERE name = 'epoch'")->fetchColumn();
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
        self::json(['seq' => $seq, 'epoch' => $epoch, 'items' => $out]);
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

    /** Übersicht: Geräte, Daten je Kategorie, Anmeldungen, Sync-Passwort (für /status und /admin). */
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

    // ───────────────────────────── Zurücksetzen mit E-Mail-Bestätigung ──

    public static function mask(string $mail): string
    {
        if (!str_contains($mail, '@')) return $mail;
        [$a, $d] = explode('@', $mail, 2);
        return mb_substr($a, 0, 2) . str_repeat('•', max(1, mb_strlen($a) - 2)) . '@' . $d;
    }

    /** Bestätigungslink per E-Mail senden (30 Minuten, einmal, nur für dieselbe Person). Gibt die Adresse zurück. */
    private static function startReset(string $sub, string $email, string $name, string $from): string
    {
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            self::fail(400, 'Für dein SSO-Konto ist keine E-Mail-Adresse bekannt – Zurücksetzen ist so nicht möglich');
        }
        $code = bin2hex(random_bytes(32));
        $tooMany = false;
        self::store('resets.json', function (array $all) use ($code, $sub, &$tooMany) {
            $n = 0;
            foreach ($all as $k => $r) {
                if ((int)$r['t'] < time() - 3600) { unset($all[$k]); continue; }
                if ($r['sub'] === $sub) $n++;
            }
            if ($n >= 3) { $tooMany = true; return $all; }
            $all[hash('sha256', $code)] = ['sub' => $sub, 't' => time()];
            return $all;
        });
        if ($tooMany) self::fail(429, 'Zu viele Anfragen – bitte in einer Stunde erneut versuchen');
        $host = (string)($_SERVER['HTTP_HOST'] ?? 'agent.2442.io');
        $base = defined('JUNELS_BASE') ? (string)JUNELS_BASE : '';
        $link = 'https://' . $host . $base . '/admin/bestaetigen/' . $code;
        $fromAddr = defined('JUNELS_MAIL_FROM') ? (string)JUNELS_MAIL_FROM
            : (string)(getenv('JUNELS_MAIL_FROM') ?: getenv('MAIL_FROM') ?: ($_ENV['MAIL_FROM'] ?? '') ?: ('noreply@' . preg_replace('/^(agent|q|t)\./', '', $host)));
        $subject = '=?UTF-8?B?' . base64_encode('Junels: Sync-Passwort zurücksetzen bestätigen') . '?=';
        $text = "Hallo" . ($name !== '' ? " $name" : '') . ",\n\n"
            . "jemand (hoffentlich du, über: $from) möchte das Sync-Passwort deines Junels-Kontos zurücksetzen.\n"
            . "Dabei werden alle Daten dieses Kontos auf dem Server gelöscht. Auf deinen Geräten bleibt alles erhalten.\n\n"
            . "Zum Bestätigen diesen Link öffnen (30 Minuten gültig, Anmeldung mit deinem SSO-Konto nötig):\n$link\n\n"
            . "Warst du das nicht? Dann ignoriere diese E-Mail – es passiert nichts.\n\nJunels";
        $headers = "From: Junels <$fromAddr>\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\nMIME-Version: 1.0";
        if (!@mail($email, $subject, $text, $headers)) self::fail(500, 'E-Mail konnte nicht gesendet werden');
        if (class_exists('Weiche')) Weiche::log('[junels-api] Zurücksetzen angefordert (' . $from . ')');
        return $email;
    }

    /** Link aus der E-Mail: anzeigen (GET) und erst nach Klick zurücksetzen (POST) – mit SSO derselben Person. */
    public static function confirmReset(string $code, string $here, bool $post): never
    {
        self::sso();
        $u = Sso::guard($here);
        $sub = (string)$u['sub'];
        $k = hash('sha256', $code);
        $r = self::store('resets.json')[$k] ?? null;
        if (!$r || (int)$r['t'] < time() - 1800) {
            self::page('Link abgelaufen', '<p>Dieser Bestätigungslink ist abgelaufen oder wurde schon benutzt.</p>'
                . '<p><a href="' . htmlspecialchars((defined('JUNELS_BASE') ? (string)JUNELS_BASE : '') . '/admin') . '">Zur Konto-Übersicht</a></p>');
        }
        if (!hash_equals((string)$r['sub'], $sub)) self::fail(403, 'Dieser Link gehört zu einem anderen Konto – mit dem richtigen SSO-Konto anmelden');
        if (!$post) {
            $csrf = self::csrf($sub);
            self::page('Sync-Passwort zurücksetzen', '<p>Angemeldet als <strong>' . htmlspecialchars((string)(($u['name'] ?? '') ?: ($u['email'] ?? ''))) . '</strong>.</p>'
                . '<p>Jetzt werden <strong>alle Daten dieses Kontos auf dem Server gelöscht</strong> und das Sync-Passwort freigegeben. '
                . 'Auf deinen Geräten bleibt alles erhalten.</p>'
                . '<form method="post"><input type="hidden" name="csrf" value="' . $csrf . '"><button class="danger">Jetzt zurücksetzen</button></form>');
        }
        if (!hash_equals(self::csrf($sub), (string)($_POST['csrf'] ?? ''))) self::fail(403, 'Ungültiges Formular – Link erneut öffnen');
        self::store('resets.json', function (array $all) use ($k) { unset($all[$k]); return $all; });   // nur einmal
        $dir = self::userDir($sub);
        foreach (array_merge(glob($dir . '/*.sqlite') ?: [], glob($dir . '/*.json') ?: []) as $f) @unlink($f);
        @unlink($dir . '/allowed.txt');
        if (class_exists('Weiche')) Weiche::log('[junels-api] Sync-Passwort zurückgesetzt');
        self::page('Zurückgesetzt', '<p>Erledigt: Die Serverdaten sind gelöscht, das Sync-Passwort ist frei.</p>'
            . '<p>In Junels: Einstellungen → Konto, Datenschutz &amp; Abgleich → neues Sync-Passwort festlegen (oder das bisherige behalten) und abgleichen. '
            . 'Auf den anderen Geräten dasselbe Passwort eintragen.</p>');
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
            '<form method="post" action="' . $h($base . '/admin/' . $action) . '" style="display:inline">'
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

        // Sync-Passwort zurücksetzen (2. Faktor per E-Mail)
        $b .= '<h2>Sync-Passwort zurücksetzen</h2><p class="muted">Das Sync-Passwort verschlüsselt deine Daten auf dem Gerät – niemand kann es wiederherstellen. '
            . 'Zurücksetzen löscht deshalb alle Daten dieses Kontos auf dem Server; danach legst du in der App ein neues Passwort fest und die Geräte laden '
            . 'ihre Daten wieder hoch (auf den Geräten geht nichts verloren). Zur Sicherheit bekommst du einen Bestätigungslink per E-Mail.</p>'
            . $form('zuruecksetzen', 'Bestätigungs-E-Mail senden', 'danger', 'Ja, Sync-Passwort zurücksetzen und Serverdaten löschen');

        self::page('Junels – Konto', $b, true);
    }

    public static function accountAction(string $action, string $back): never
    {
        self::sso();
        $u = Sso::guard($back);
        $sub = (string)$u['sub'];
        if (!hash_equals(self::csrf($sub), (string)($_POST['csrf'] ?? ''))) self::fail(403, 'Ungültiges Formular – Seite neu laden');
        $dir = self::userDir($sub);
        if ($action === 'zuruecksetzen') {
            if (($_POST['ok'] ?? '') !== '1') self::fail(400, 'Bitte bestätigen');
            $mail = self::startReset($sub, (string)($u['email'] ?? ''), (string)($u['name'] ?? ''), 'Browser');
            self::page('E-Mail unterwegs', '<p>Wir haben einen Bestätigungslink an <strong>' . htmlspecialchars(self::mask($mail)) . '</strong> geschickt.</p>'
                . '<p>Öffne ihn innerhalb von 30 Minuten – angemeldet mit demselben SSO-Konto. Erst dann wird zurückgesetzt.</p>'
                . '<p class="muted">Keine E-Mail? Spam-Ordner prüfen oder in ein paar Minuten erneut versuchen.</p>');
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
