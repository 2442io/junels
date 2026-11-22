<?php
/**
 * Junels Agent-API – Logik. Speicher: Kanal-Speicher der Weiche (JUNELS_STORAGE/junels).
 */
declare(strict_types=1);

final class Api
{
    const MAX_BODY = 64 * 1024 * 1024;

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
            . '<p>In Junels: Einstellungen → Konto, Daten &amp; Abgleich → „Mit SSO anmelden“.</p>');
    }

    /** App-Anmeldung: SSO, dann Token an die App auf diesem Gerät (127.0.0.1:<port>/sso/<token>). */
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
        $fh = fopen(self::storage() . '/tokens.json', 'c+');
        if ($fh === false) self::fail(500, 'tokens.json nicht schreibbar');
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
        $dir = self::storage() . '/u-' . substr(hash('sha256', 'junels:' . $who['sub']), 0, 32);
        self::dir($dir);

        switch ($action) {
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
        self::json(['seq' => $seq, 'items' => $out]);
    }

    public static function page(string $title, string $body): never
    {
        header('Content-Type: text/html; charset=utf-8');
        echo '<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            . '<meta name="robots" content="noindex"><title>' . htmlspecialchars($title) . '</title><style>'
            . 'body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f5f2;color:#1c1c1a;font:16px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif}'
            . 'main{max-width:440px;margin:16px;background:#fff;border:1px solid #e3e1db;border-radius:12px;padding:28px}h1{font-size:22px;margin:0 0 8px}'
            . '@media(prefers-color-scheme:dark){body{background:#141413;color:#eee}main{background:#1e1e1c;border-color:#34332f}}'
            . '</style></head><body><main><h1>' . htmlspecialchars($title) . '</h1>' . $body . '</main></body></html>';
        exit;
    }
}
