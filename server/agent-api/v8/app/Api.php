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
            case 'stats':
                // Auswertung aus der App: nur Zahlen und Kategorien (keine Inhalte)
                $st = $req['stats'] ?? null;
                if (!is_array($st) || (int)($st['v'] ?? 0) !== 1) self::fail(400, 'ungültige Auswertung');
                $clean = self::cleanStats($st);
                @file_put_contents("$dir/stats.json", json_encode($clean));
                self::json(['ok' => true]);
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

    /** Auswertung prüfen: nur erwartete Felder, Zahlen und kurze Namen */
    private static function cleanStats(array $s): array
    {
        $num = fn($v) => is_numeric($v) ? 0 + $v : 0;
        $name = fn($v) => mb_substr(preg_replace('/[^\p{L}\p{N} &().,\-+…\/]/u', '', (string)$v), 0, 40);
        $list = function ($l, int $max) use ($num, $name) {
            $o = [];
            foreach (is_array($l) ? array_slice($l, 0, $max) : [] as $e) if (is_array($e)) $o[] = ['n' => $name($e['n'] ?? ''), 'v' => $num($e['v'] ?? 0)];
            return $o;
        };
        $kpi = [];
        foreach (['chats', 'messages', 'answers', 'activeDays', 'usageHours', 'agentHours', 'tokens', 'savedHours', 'docs', 'voice', 'transcripts', 'automations', 'local', 'cloud'] as $k) {
            $kpi[$k] = $num($s['kpi'][$k] ?? 0);
        }
        $weeks = [];
        foreach (is_array($s['weeks'] ?? null) ? array_slice($s['weeks'], 0, 26) : [] as $w) {
            if (is_array($w)) $weeks[] = ['w' => preg_replace('/[^0-9W-]/', '', (string)($w['w'] ?? '')), 'm' => $num($w['m'] ?? 0), 's' => $num($w['s'] ?? 0)];
        }
        $hours = [];
        for ($i = 0; $i < 24; $i++) $hours[] = $num($s['hours'][$i] ?? 0);
        return [
            'v' => 1, 'received' => time(), 'generated' => (int)$num($s['generated'] ?? time()), 'since' => (int)$num($s['since'] ?? 0),
            'device' => $name($s['device'] ?? ''), 'kpi' => $kpi, 'weeks' => $weeks, 'hours' => $hours,
            'topics' => $list($s['topics'] ?? [], 12), 'features' => $list($s['features'] ?? [], 14),
            'saved' => $list($s['saved'] ?? [], 12), 'skills' => $list($s['skills'] ?? [], 8),
        ];
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
        $text = "Hallo" . ($name !== '' ? " $name" : '') . ",\n\n"
            . "jemand (hoffentlich du, über: $from) möchte das Sync-Passwort deines Junels-Kontos zurücksetzen.\n"
            . "Dabei werden alle Daten dieses Kontos auf dem Server gelöscht. Auf deinen Geräten bleibt alles erhalten.\n\n"
            . "Zum Bestätigen diesen Link öffnen (30 Minuten gültig, Anmeldung mit deinem SSO-Konto nötig):\n$link\n\n"
            . "Warst du das nicht? Dann ignoriere diese E-Mail – es passiert nichts.\n\nJunels";
        $err = null;
        if (!Mailer::send($email, 'Junels: Sync-Passwort zurücksetzen bestätigen', $text, $err, 'noreply@' . preg_replace('/^(agent|q|t)\./', '', $host))) {
            if (class_exists('Weiche')) Weiche::log('[junels-api] E-Mail fehlgeschlagen: ' . $err . ' · ' . Mailer::describe());
            // der Rücksetz-Code gilt nicht, wenn die E-Mail nicht rausging
            self::store('resets.json', function (array $all) use ($code) { unset($all[hash('sha256', $code)]); return $all; });
            if ($from === 'Browser') self::mailFailPage((string)$err);
            self::fail(500, 'E-Mail konnte nicht gesendet werden: ' . $err);
        }
        if (class_exists('Weiche')) Weiche::log('[junels-api] Zurücksetzen angefordert (' . $from . ')');
        return $email;
    }

    private static function mailFailPage(string $err): never
    {
        http_response_code(500);
        $base = defined('JUNELS_BASE') ? (string)JUNELS_BASE : '';
        self::page('E-Mail konnte nicht gesendet werden', '<div class="alert">' . htmlspecialchars($err) . '</div>'
            . '<p class="muted">Einstellungen: ' . htmlspecialchars(Mailer::describe()) . '</p>'
            . '<p>Prüfen: <code>MAIL_HOST</code>, <code>MAIL_PORT</code> (465 = SSL), <code>MAIL_USER</code>, <code>MAIL_PASS</code> und <code>MAIL_FROM</code> '
            . 'in der env des Kanals (z. B. <code>env/prod.env</code>). Der Absender muss zum Postfach passen.</p>'
            . '<p><a class="btn" href="' . htmlspecialchars($base . '/admin#sicherheit') . '">Zurück</a></p>');
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

    /** Admin-Bereich im Browser (SSO): Übersicht, Analytics, Geräte, Daten, Sicherheit. */
    public static function account(string $here): never
    {
        self::sso();
        $u = Sso::guard($here);
        $sub = (string)$u['sub'];
        date_default_timezone_set('Europe/Vienna');
        $dir = self::userDir($sub);
        $o = self::overview($dir, $sub);
        $st = json_decode((string)@file_get_contents("$dir/stats.json"), true) ?: null;
        $h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES);
        $when = fn(int $t) => $t ? date('d.m.Y H:i', $t) : '–';
        $size = fn(int $b) => $b >= 1048576 ? number_format($b / 1048576, 1, ',', '.') . ' MB' : number_format(max(1, (int)round($b / 1024)), 0, ',', '.') . ' KB';
        $n = fn($v, int $d = 0) => number_format((float)$v, $d, ',', '.');
        $hrs = fn($v) => (float)$v < 1 ? $n(round((float)$v * 60)) . ' min' : $n($v, (float)$v < 10 ? 1 : 0) . ' h';
        $csrf = self::csrf($sub);
        $base = defined('JUNELS_BASE') ? (string)JUNELS_BASE : '';
        $form = fn(string $action, string $label, string $cls = '', string $confirm = '') =>
            '<form method="post" action="' . $h($base . '/admin/' . $action) . '" class="inline">'
            . '<input type="hidden" name="csrf" value="' . $csrf . '">'
            . ($confirm ? '<label class="check"><input type="checkbox" name="ok" value="1" required> ' . $h($confirm) . '</label>' : '')
            . '<button class="' . $cls . '">' . $h($label) . '</button></form>';
        $icon = fn(string $p) => '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' . $p . '</svg>';
        $I = [
            'save' => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
            'chat' => '<path d="M4 5h16v11H9l-5 4z"/>',
            'dev' => '<rect x="3" y="4" width="13" height="10" rx="1"/><path d="M1 18h17"/><rect x="18" y="8" width="5" height="11" rx="1"/>',
            'data' => '<ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
            'tok' => '<path d="M12 3l2 5 5 2-5 2-2 5-2-5-5-2 5-2z"/>',
            'cal' => '<rect x="4" y="5" width="16" height="16" rx="2"/><path d="M8 3v4M16 3v4M4 10h16"/>',
            'cpu' => '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
            'doc' => '<path d="M14 3H6v18h12V7z"/><path d="M14 3v4h4M9 13h6M9 17h6"/>',
            'lock' => '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
        ];
        $kpi = fn(string $ic, string $tone, string $v, string $l) => '<div class="kpi"><div class="ki t-' . $tone . '">' . $icon($I[$ic]) . '</div><b>' . $v . '</b><span>' . $h($l) . '</span></div>';
        $bars = function (array $items, string $tone, bool $hours = false) use ($h, $n, $hrs) {
            if (!$items) return '<p class="muted">Noch keine Daten.</p>';
            $max = max(array_map(fn($e) => (float)$e['v'], $items)) ?: 1;
            $o = '<div class="bars">';
            foreach ($items as $e) {
                $o .= '<div class="bar"><span class="bl">' . $h($e['n']) . '</span><span class="bt"><i class="t-' . $tone . '" style="width:' . round(100 * (float)$e['v'] / $max, 1) . '%"></i></span><span class="bv">'
                    . ($hours ? $hrs($e['v']) : $n($e['v'])) . '</span></div>';
            }
            return $o . '</div>';
        };
        $name = ($u['name'] ?? '') ?: ($u['email'] ?? '');
        $k = $st['kpi'] ?? [];

        // ── Kopf & Übersicht
        $b = '<section class="hello"><div><span class="eyebrow">Admin-Bereich</span><h1>Hallo ' . $h(explode(' ', (string)$name)[0]) . '</h1>'
            . '<p class="muted">Inhalte sind Ende-zu-Ende verschlüsselt – hier siehst du nur, <em>was</em> und <em>wie viel</em> gespeichert ist, nie den Inhalt.</p></div></section>'
            . '<nav class="tabs"><a href="#uebersicht">Übersicht</a><a href="#analytics">Analytics</a><a href="#geraete">Geräte</a><a href="#daten">Daten</a><a href="#sicherheit">Sicherheit</a></nav>';
        $b .= '<section id="uebersicht" class="sec"><div class="kpis">'
            . $kpi('save', 'mint', $st ? $hrs($k['savedHours'] ?? 0) : '–', 'Arbeitszeit gespart (geschätzt)')
            . $kpi('chat', 'violet', $st ? $n($k['messages'] ?? 0) : '–', 'Anfragen')
            . $kpi('dev', 'sky', (string)count($o['devices']), 'Geräte')
            . $kpi('data', 'sun', $o['bytes'] ? $size((int)$o['bytes']) : '0 KB', 'verschlüsselt gespeichert')
            . '</div><p class="muted small">Letzte Änderung: ' . $when((int)$o['lastChange']) . ' · Sync-Passwort festgelegt: ' . ($o['passwordSince'] ? $when((int)$o['passwordSince']) : 'noch nicht') . '</p></section>';

        // ── Analytics
        $b .= '<section id="analytics" class="sec"><div class="sh"><h2>Analytics</h2>';
        if (!$st) {
            $b .= '</div><div class="card empty"><h3>Noch keine Auswertung</h3><p class="muted">In Junels unter <strong>Kontrolle → Auswertung</strong> „Im Admin-Bereich anzeigen“ einschalten (ab Junels 1.74). '
                . 'Beim nächsten Abgleich erscheinen hier Nutzung, Themen, Funktionen, Tokens und die geschätzte Zeitersparnis – nur als Zahlen, ohne Inhalte.</p></div></section>';
        } else {
            $b .= '<span class="muted small">Stand ' . $when((int)($st['generated'] ?? 0)) . ($st['device'] ? ' · von ' . $h($st['device']) : '') . ($st['since'] ? ' · seit ' . date('d.m.Y', (int)$st['since']) : '') . '</span></div>';
            $loc = (float)($k['local'] ?? 0); $cl = (float)($k['cloud'] ?? 0);
            $share = $loc + $cl > 0 ? round(100 * $loc / ($loc + $cl)) : 0;
            $b .= '<div class="kpis k8">'
                . $kpi('save', 'mint', $hrs($k['savedHours'] ?? 0), 'Arbeitszeit gespart')
                . $kpi('cal', 'sky', $hrs($k['usageHours'] ?? 0), 'Nutzungszeit')
                . $kpi('chat', 'violet', $n($k['messages'] ?? 0), 'Anfragen in ' . $n($k['chats'] ?? 0) . ' Chats')
                . $kpi('tok', 'sun', ($k['tokens'] ?? 0) >= 10000 ? $n(($k['tokens'] ?? 0) / 1000) . ' Tsd.' : $n($k['tokens'] ?? 0), 'Tokens (ca.)')
                . $kpi('cal', 'coral', $n($k['activeDays'] ?? 0), 'aktive Tage')
                . $kpi('cpu', 'violet', $hrs($k['agentHours'] ?? 0), 'Rechenzeit der KI')
                . $kpi('doc', 'sun', $n($k['docs'] ?? 0), 'Dokumente erstellt')
                . $kpi('lock', 'mint', $share . ' %', 'auf dem Gerät beantwortet')
                . '</div>';
            // Wochen: Balken (Anfragen) + Linie (gesparte Stunden)
            $weeks = $st['weeks'] ?? [];
            $mx = max(1, ...array_map(fn($w) => (float)$w['m'], $weeks ?: [['m' => 1]]));
            $ms = max(0.1, ...array_map(fn($w) => (float)$w['s'], $weeks ?: [['s' => 0.1]]));
            $W = 640; $H = 200; $cnt = max(1, count($weeks)); $bw = $W / $cnt;
            $svg = '<svg viewBox="0 0 ' . $W . ' ' . ($H + 24) . '" class="chart" role="img" aria-label="Anfragen je Woche">';
            for ($g = 0; $g <= 4; $g++) $svg .= '<line x1="0" x2="' . $W . '" y1="' . (10 + ($H - 10) * $g / 4) . '" y2="' . (10 + ($H - 10) * $g / 4) . '" class="grid"/>';
            $pts = [];
            foreach ($weeks as $i => $w) {
                $bh = ($H - 10) * (float)$w['m'] / $mx;
                $x = $i * $bw + $bw * 0.2;
                $svg .= '<rect x="' . round($x, 1) . '" y="' . round($H - $bh, 1) . '" width="' . round($bw * 0.6, 1) . '" height="' . round(max(1, $bh), 1) . '" rx="5" class="b"><title>' . $h($w['w']) . ': ' . (int)$w['m'] . ' Anfragen · ' . $hrs($w['s']) . ' gespart</title></rect>';
                $svg .= '<text x="' . round($x + $bw * 0.3, 1) . '" y="' . ($H + 18) . '" class="lbl">' . $h(substr((string)$w['w'], -3)) . '</text>';
                $pts[] = round($i * $bw + $bw / 2, 1) . ',' . round($H - ($H - 10) * (float)$w['s'] / $ms, 1);
            }
            if ($pts) $svg .= '<polyline points="' . implode(' ', $pts) . '" class="ln"/>';
            foreach ($pts as $p) { [$px, $py] = explode(',', $p); $svg .= '<circle cx="' . $px . '" cy="' . $py . '" r="4" class="dot"/>'; }
            $svg .= '</svg>';
            $b .= '<div class="grid2"><div class="card wide"><h3>Verlauf der letzten Wochen</h3><p class="legend"><i class="lg b"></i> Anfragen <i class="lg l"></i> gesparte Stunden</p>' . $svg . '</div>';
            // Tageszeit
            $hrsArr = $st['hours'] ?? [];
            $hm = max(1, ...array_map('floatval', $hrsArr ?: [1]));
            $hs = '<div class="hours">';
            foreach ($hrsArr as $i => $v) $hs .= '<span title="' . $i . ' Uhr: ' . (int)$v . '"><i style="height:' . round(4 + 86 * (float)$v / $hm) . 'px;opacity:' . round(0.3 + 0.7 * (float)$v / $hm, 2) . '"></i><em>' . ($i % 6 === 0 ? $i : '') . '</em></span>';
            $hs .= '</div>';
            // Gerät vs. Cloud (Ring)
            $C = 2 * M_PI * 42; $off = $C * (1 - $share / 100);
            $ring = '<svg viewBox="0 0 120 120" class="ring"><circle cx="60" cy="60" r="42" class="rb"/><circle cx="60" cy="60" r="42" class="rf" stroke-dasharray="' . round($C, 1) . '" stroke-dashoffset="' . round($off, 1) . '"/><text x="60" y="58" class="rv">' . $share . '%</text><text x="60" y="76" class="rl">Gerät</text></svg>';
            $b .= '<div class="card"><h3>Tageszeit</h3>' . $hs . '</div><div class="card"><h3>Gerät oder Cloud</h3><div class="ringwrap">' . $ring
                . '<p class="muted small">' . $n($loc) . ' Antworten lokal<br>' . $n($cl) . ' über Server/Cloud</p></div></div>';
            $b .= '<div class="card"><h3>Themengebiete</h3>' . $bars($st['topics'] ?? [], 'violet') . '</div>';
            $b .= '<div class="card"><h3>Funktionen</h3>' . $bars($st['features'] ?? [], 'sky') . '</div>';
            $b .= '<div class="card"><h3>Gesparte Zeit nach Art</h3>' . $bars($st['saved'] ?? [], 'mint', true) . '</div>';
            if (!empty($st['skills'])) $b .= '<div class="card"><h3>Skills</h3>' . $bars($st['skills'], 'sun') . '</div>';
            $b .= '</div><p class="muted small">Geschätzt aus der Nutzung (z. B. Web-Recherche 8 min, Word-Dokument 25 min, Präsentation 40 min, Mitschrift 1,5 × Gesprächsdauer). '
                . 'Berechnet in der App, übertragen werden nur diese Zahlen.</p></section>';
        }

        // ── Geräte
        $b .= '<section id="geraete" class="sec"><h2>Geräte</h2>';
        if (!$o['devices']) $b .= '<div class="card"><p class="muted">Noch kein Gerät hat sich mit Namen gemeldet (ab Junels 1.69 sichtbar).</p></div>';
        $b .= '<div class="devs">';
        foreach ($o['devices'] as $d) {
            $b .= '<div class="card dev"><div class="ki t-sky">' . $icon($I['dev']) . '</div><div class="grow"><strong>' . $h($d['name']) . '</strong><br><span class="muted small">'
                . $h($d['platform']) . ($d['app'] ? ' · Junels ' . $h($d['app']) : '') . '<br>Letzter Abgleich ' . $when((int)$d['last']) . ' · ' . (int)$d['syncs'] . ' Abgleiche</span></div>'
                . $form('geraet-entfernen/' . $h($d['id']), 'Entfernen', 'small') . '</div>';
        }
        $b .= '</div></section>';

        // ── Daten
        $b .= '<section id="daten" class="sec"><h2>Daten</h2><div class="card">';
        if (!$o['categories']) {
            $b .= '<p class="muted">Keine Daten gespeichert.</p>';
        } else {
            $b .= '<table><tr class="th"><td>Bereich</td><td class="r">Einträge</td><td class="r">Größe</td><td class="r">Zuletzt</td></tr>';
            foreach ($o['categories'] as $c) {
                $b .= '<tr><td>' . $h($c['label']) . '</td><td class="r">' . (int)$c['count'] . '</td><td class="r">' . $size((int)$c['bytes']) . '</td><td class="r muted">' . $when((int)$c['last']) . '</td></tr>';
            }
            $b .= '<tr class="sum"><td>Gesamt</td><td></td><td class="r">' . $size((int)$o['bytes']) . '</td><td class="r muted">' . $when((int)$o['lastChange']) . '</td></tr></table>';
        }
        $b .= '</div></section>';

        // ── Sicherheit
        $b .= '<section id="sicherheit" class="sec"><h2>Sicherheit</h2><div class="grid2"><div class="card"><h3>Angemeldete Apps</h3>';
        if (!$o['sessions']) $b .= '<p class="muted">Keine.</p>';
        foreach ($o['sessions'] as $s) {
            $b .= '<div class="row"><div>Anmeldung vom ' . $when((int)$s['since']) . '<br><span class="muted small">zuletzt genutzt ' . $when((int)$s['used']) . '</span></div>'
                . $form('abmelden/' . $h($s['id']), 'Abmelden', 'small') . '</div>';
        }
        $b .= '</div><div class="card"><h3>E-Mail-Versand</h3><p class="muted small">Für die Bestätigung beim Zurücksetzen. Hier kannst du ihn prüfen.</p>'
            . $form('testmail', 'Test-E-Mail an mich senden', 'small') . '</div>';
        $b .= '<div class="card wide danger-zone"><h3>Sync-Passwort zurücksetzen</h3><p class="muted">Das Sync-Passwort verschlüsselt deine Daten auf dem Gerät – niemand kann es wiederherstellen. '
            . 'Zurücksetzen löscht deshalb alle Daten dieses Kontos auf dem Server; danach legst du in der App ein neues Passwort fest und die Geräte laden '
            . 'ihre Daten wieder hoch (auf den Geräten geht nichts verloren). Zur Sicherheit bekommst du einen Bestätigungslink per E-Mail.</p>'
            . $form('zuruecksetzen', 'Bestätigungs-E-Mail senden', 'danger', 'Ja, Sync-Passwort zurücksetzen und Serverdaten löschen') . '</div></div></section>';

        self::page('Junels – Admin', $b, true, true);
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
        } elseif ($action === 'testmail') {
            $email = (string)($u['email'] ?? '');
            if (!filter_var($email, FILTER_VALIDATE_EMAIL)) self::page('Test-E-Mail', '<div class="alert">Für dein SSO-Konto ist keine E-Mail-Adresse bekannt.</div>');
            $err = null;
            $ok = Mailer::send($email, 'Junels: Test-E-Mail', "Hallo,\n\ndiese Test-E-Mail kommt von deiner Junels Agent-API (" . ($_SERVER['HTTP_HOST'] ?? '') . ").\nDer E-Mail-Versand funktioniert.\n\nJunels", $err);
            if (class_exists('Weiche')) Weiche::log('[junels-api] Test-E-Mail ' . ($ok ? 'gesendet' : 'fehlgeschlagen: ' . $err));
            if (!$ok) self::mailFailPage((string)$err);
            self::page('Test-E-Mail gesendet', '<p>Die Test-E-Mail ist an <strong>' . htmlspecialchars(self::mask($email)) . '</strong> unterwegs.</p>'
                . '<p class="muted">' . htmlspecialchars(Mailer::describe()) . '</p><p><a class="btn" href="' . htmlspecialchars($back . '#sicherheit') . '">Zurück</a></p>');
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

    public static function page(string $title, string $body, bool $wide = false, bool $raw = false): never
    {
        $base = htmlspecialchars(defined('JUNELS_BASE') ? (string)JUNELS_BASE : '');
        header('Content-Type: text/html; charset=utf-8');
        echo '<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            . '<meta name="robots" content="noindex"><meta name="theme-color" content="#fffaf3"><title>' . htmlspecialchars($title) . '</title><style>'
            . ':root{--bg:#fffaf3;--ink:#1d2433;--mut:#5d6577;--line:#ece6dc;--mint:#12b886;--mint2:#e3f8f0;--sky:#3b82f6;--sky2:#e6efff;--coral:#ff6b5b;--coral2:#ffe9e5;--sun:#d98a00;--sun2:#fff3dc;--vio:#8b5cf6;--vio2:#f0eaff;--sh:0 1px 2px rgba(29,36,51,.04),0 12px 32px -14px rgba(29,36,51,.16)}'
            . '*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,Arial,sans-serif}'
            . 'a{color:inherit}header.top{position:sticky;top:0;z-index:5;background:rgba(255,250,243,.85);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}'
            . 'header.top div{max-width:1100px;margin:0 auto;padding:0 20px;height:60px;display:flex;align-items:center;gap:18px}'
            . '.logo{display:flex;align-items:center;gap:9px;font-weight:800;font-size:19px;text-decoration:none}.logo b{display:grid;place-items:center;width:30px;height:30px;border-radius:10px;background:linear-gradient(135deg,#12b886,#3b82f6 60%,#8b5cf6);color:#fff;font-size:16px}'
            . 'header.top nav{margin-left:auto;display:flex;gap:18px;font-size:14px;font-weight:600}header.top nav a{text-decoration:none;color:var(--mut)}header.top nav a:hover{color:var(--ink)}'
            . 'main{max-width:' . ($wide ? '1100' : '560') . 'px;margin:0 auto;padding:28px 20px 60px}'
            . ($raw ? '' : 'main>.box{background:#fff;border:1px solid var(--line);border-radius:22px;padding:28px;box-shadow:var(--sh)}main>.box>h1{font-size:26px;margin:0 0 12px;letter-spacing:-.02em}')
            . 'h1,h2,h3{letter-spacing:-.02em}h2{font-size:24px;margin:0 0 14px}h3{font-size:16px;margin:0 0 12px}.muted{color:var(--mut)}.small{font-size:13px}'
            . '.eyebrow{display:inline-block;font-size:12px;font-weight:750;text-transform:uppercase;letter-spacing:.08em;color:var(--mint);background:var(--mint2);padding:4px 11px;border-radius:999px}'
            . '.hello h1{font-size:clamp(30px,5vw,44px);margin:12px 0 6px}.hello p{max-width:700px;margin:0}'
            . '.tabs{position:sticky;top:60px;z-index:4;display:flex;gap:8px;overflow-x:auto;margin:22px -20px 0;padding:10px 20px;background:rgba(255,250,243,.92);backdrop-filter:blur(8px);border-bottom:1px solid var(--line)}'
            . '.tabs a{white-space:nowrap;text-decoration:none;font-size:14px;font-weight:600;padding:7px 14px;border-radius:999px;background:#fff;border:1px solid var(--line);color:var(--mut)}.tabs a:hover{color:var(--ink);border-color:var(--mint)}'
            . '.sec{padding-top:34px;scroll-margin-top:120px}.sh{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:12px}.sh h2{margin:0}'
            . '.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}.kpi{background:#fff;border:1px solid var(--line);border-radius:18px;padding:16px;box-shadow:var(--sh)}'
            . '.kpi b{display:block;font-size:26px;font-weight:800;letter-spacing:-.03em;margin-top:8px}.kpi span{color:var(--mut);font-size:13px}'
            . '.ki{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;background:var(--c2);color:var(--c);flex:none}'
            . '.t-mint{--c:var(--mint);--c2:var(--mint2)}.t-sky{--c:var(--sky);--c2:var(--sky2)}.t-coral{--c:var(--coral);--c2:var(--coral2)}.t-sun{--c:var(--sun);--c2:var(--sun2)}.t-violet{--c:var(--vio);--c2:var(--vio2)}'
            . '.card{background:#fff;border:1px solid var(--line);border-radius:20px;padding:20px;box-shadow:var(--sh)}.card.empty{text-align:center;padding:34px}'
            . '.grid2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin-top:14px}.grid2 .wide{grid-column:1/-1}'
            . '.bars{display:grid;gap:9px}.bar{display:grid;grid-template-columns:minmax(90px,170px) 1fr 64px;gap:10px;align-items:center;font-size:14px}.bl{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}'
            . '.bt{height:10px;border-radius:9px;background:#f3efe8;overflow:hidden}.bt i{display:block;height:100%;border-radius:9px;background:var(--c)}.bv{text-align:right;color:var(--mut);font-size:13px}'
            . '.chart{width:100%;height:auto}.chart .grid{stroke:#f0ebe2}.chart .b{fill:#c9dafc}.chart .b:hover{fill:var(--sky)}.chart .ln{fill:none;stroke:var(--mint);stroke-width:3;stroke-linejoin:round}.chart .dot{fill:#fff;stroke:var(--mint);stroke-width:2.5}'
            . '.chart .lbl{font-size:11px;fill:var(--mut);text-anchor:middle}.legend{font-size:13px;color:var(--mut);margin:-6px 0 8px}.lg{display:inline-block;width:12px;height:12px;border-radius:4px;vertical-align:-1px;margin:0 4px 0 10px}.lg.b{background:#c9dafc}.lg.l{background:var(--mint)}'
            . '.hours{display:flex;align-items:flex-end;gap:3px;height:110px}.hours span{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:flex-end;height:100%}.hours i{display:block;width:100%;border-radius:4px;background:var(--vio)}.hours em{font-style:normal;font-size:11px;color:var(--mut);height:16px}'
            . '.ringwrap{display:flex;align-items:center;gap:18px}.ring{width:130px;height:130px}.ring .rb{fill:none;stroke:#f0ebe2;stroke-width:12}.ring .rf{fill:none;stroke:var(--mint);stroke-width:12;stroke-linecap:round;transform:rotate(-90deg);transform-origin:center}'
            . '.ring .rv{font-size:22px;font-weight:800;text-anchor:middle;fill:var(--ink)}.ring .rl{font-size:11px;text-anchor:middle;fill:var(--mut)}'
            . '.devs{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px}.dev{display:flex;gap:14px;align-items:center}.grow{flex:1;min-width:0}'
            . '.row{display:flex;gap:12px;align-items:center;justify-content:space-between;padding:10px 0;border-top:1px solid var(--line)}.row:first-of-type{border-top:0}'
            . 'table{width:100%;border-collapse:collapse;font-size:15px}td{padding:9px 6px;border-top:1px solid var(--line)}tr.th td{border-top:0;color:var(--mut);font-size:13px;font-weight:600}.r{text-align:right}.sum td{font-weight:700}'
            . 'button,.btn{font:inherit;font-weight:650;border:1px solid var(--ink);background:var(--ink);color:#fff;border-radius:12px;padding:10px 16px;cursor:pointer;text-decoration:none;display:inline-block}'
            . 'button.small{background:#fff;color:var(--ink);border-color:var(--line);padding:6px 12px;font-size:14px}button.small:hover{border-color:var(--ink)}button.danger{background:#d64545;border-color:#d64545}'
            . 'form.inline{display:inline}.check{display:block;margin:8px 0 12px;font-size:14px}.danger-zone{border-color:#f3c9c4}'
            . '.alert{background:var(--coral2);color:#8a2a20;border-radius:14px;padding:14px 16px;margin:0 0 14px;font-weight:600}code{background:#f3efe8;border-radius:6px;padding:1px 6px;font-size:13px}'
            . '@media(max-width:820px){.kpis{grid-template-columns:repeat(2,1fr)}.grid2{grid-template-columns:1fr}header.top nav a.hide{display:none}}'
            . '</style></head><body><header class="top"><div><a class="logo" href="' . $base . '/"><b>J</b>Junels</a><nav><a class="hide" href="' . $base . '/">Webseite</a><a href="' . $base . '/admin">Admin</a><a class="hide" href="' . $base . '/api">API</a></nav></div></header>'
            . '<main>' . ($raw ? $body : '<div class="box"><h1>' . htmlspecialchars($title) . '</h1>' . $body . '</div>') . '</main></body></html>';
        exit;
    }
}
