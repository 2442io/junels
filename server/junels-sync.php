<?php
/*
 * Junels Sync-Server – Abgleich von Chats, Gedächtnis, Prompts usw. zwischen deinen Geräten.
 *
 * Installation: diese eine Datei auf deinen Webspace laden (PHP 7.4+, z. B. nach
 * https://deine-domain/junels/junels-sync.php) und die Adresse in Junels unter
 * „Abgleich“ eintragen. Fertig.
 *
 * Sicherheit:
 *  - Die Daten werden auf dem Gerät verschlüsselt (ChaCha20 + HMAC-SHA256, Schlüssel aus
 *    deinem Sync-Passwort). Der Server sieht nur unlesbare Blöcke und eine Konto-Kennung.
 *  - Standardmäßig wird der Server an das erste Konto gebunden, das sich meldet
 *    (Datei junels-data/allowed.txt). Andere Konten werden abgewiesen.
 *  - Der Datenordner junels-data/ wird per .htaccess gesperrt.
 *
 * Optional – Anmeldung mit SSO (z. B. sso.2442.io):
 *  1. sso-client.php aus der SSO-Verwaltung herunterladen und NEBEN diese Datei legen.
 *  2. Diese Datei einmal im Browser mit ?login=1 öffnen, „Mit SSO verbinden“ klicken und im SSO bestätigen.
 *  3. In Junels unter „Konto & Daten“ → „Mit SSO anmelden“.
 *  Dann gilt: nur angemeldete Personen dürfen abgleichen, jede Person hat ihren eigenen Speicher.
 *  Die Daten bleiben trotzdem auf dem Gerät verschlüsselt – auch das SSO und dieser Server sehen sie nicht.
 */
declare(strict_types=1);

const MAX_BODY = 64 * 1024 * 1024;   // größte Anfrage (Bytes)
const LOCK_TO_FIRST_ACCOUNT = true; // nur das erste Konto zulassen

$SSO = is_file(__DIR__ . '/sso-client.php');   // SSO-Modus, sobald sso-client.php daneben liegt
$baseDir = __DIR__ . '/junels-data';

function dataDir(string $dir): void {
    if (!is_dir($dir) && !@mkdir($dir, 0700, true)) fail(500, 'Datenordner kann nicht angelegt werden (Schreibrechte?)');
    if (!file_exists("$dir/.htaccess")) {
        file_put_contents("$dir/.htaccess", "Require all denied\n<IfModule !mod_authz_core.c>\nDeny from all\n</IfModule>\n");
    }
    if (!file_exists("$dir/index.html")) file_put_contents("$dir/index.html", '');
}

/** App-Anmeldungen: Hash des Tokens → Person (sub, Name, E-Mail). */
function tokens(string $base, ?callable $change = null): array {
    $fh = fopen("$base/tokens.json", 'c+');
    if ($fh === false) fail(500, 'tokens.json nicht schreibbar');
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

// ---- SSO-Anmeldung für die App: Browser → SSO → zurück zu Junels (127.0.0.1:PORT)
if ($SSO && isset($_GET['login'])) {
    require __DIR__ . '/sso-client.php';
    $user = Sso::guard();   // leitet zum SSO um und kommt hierher zurück
    $port = (int)($_GET['port'] ?? 0);
    header('Cache-Control: no-store');
    if ($port < 1024 || $port > 65535) {
        header('Content-Type: text/html; charset=utf-8');
        echo '<!doctype html><meta charset="utf-8"><title>Junels</title><p style="font:16px system-ui;margin:40px">'
            . 'SSO ist verbunden. Melde dich jetzt in Junels unter „Konto &amp; Daten“ → „Mit SSO anmelden“ an.</p>';
        exit;
    }
    dataDir($baseDir);
    $token = bin2hex(random_bytes(32));
    $entry = ['sub' => (string)$user['sub'], 'name' => (string)($user['name'] ?? ''), 'email' => (string)($user['email'] ?? ''), 't' => time()];
    tokens($baseDir, function (array $all) use ($token, $entry) {
        $all[hash('sha256', $token)] = $entry;
        return $all;
    });
    header('Location: http://127.0.0.1:' . $port . '/sso?' . http_build_query(['token' => $token, 'name' => $entry['name'], 'email' => $entry['email']]), true, 302);
    exit;
}

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function fail(int $code, string $msg): void {
    http_response_code($code);
    echo json_encode(['error' => $msg], JSON_UNESCAPED_UNICODE);
    exit;
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
if ($method === 'GET') {
    echo json_encode(['ok' => true, 'app' => 'junels-sync', 'v' => 2, 'sso' => $SSO,
        'storage' => extension_loaded('pdo_sqlite') ? 'sqlite' : 'json']);
    exit;
}
if ($method !== 'POST') fail(405, 'nur POST');

$raw = file_get_contents('php://input', false, null, 0, MAX_BODY + 1);
if ($raw === false || strlen($raw) > MAX_BODY) fail(413, 'Anfrage zu groß');
$req = json_decode($raw, true);
if (!is_array($req)) fail(400, 'kein gültiges JSON');

dataDir($baseDir);
$dir = $baseDir;
if ($SSO) {
    // Nur angemeldete Personen; jede hat ihren eigenen Ordner
    $tok = (string)($req['token'] ?? '');
    $who = $tok !== '' ? (tokens($baseDir)[hash('sha256', $tok)] ?? null) : null;
    if (!$who) fail(401, 'Bitte in Junels (neu) mit SSO anmelden');
    if (!empty($req['logout'])) {
        tokens($baseDir, function (array $all) use ($tok) { unset($all[hash('sha256', $tok)]); return $all; });
        echo json_encode(['ok' => true]);
        exit;
    }
    if (!empty($req['whoami'])) {
        echo json_encode(['ok' => true, 'name' => $who['name'], 'email' => $who['email']], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $dir = $baseDir . '/u-' . substr(hash('sha256', 'junels:' . $who['sub']), 0, 32);
    dataDir($dir);
}

// Gespeicherte Daten dieser Person/dieses Kontos löschen (z. B. nach dem Senken der Datenschutz-Stufe)
if (!empty($req['wipe'])) {
    foreach (array_merge(glob($dir . '/*.sqlite') ?: [], glob($dir . '/*.json') ?: []) as $f) {
        if (basename($f) !== 'tokens.json') @unlink($f);
    }
    @unlink($dir . '/allowed.txt');
    echo json_encode(['ok' => true, 'wiped' => true]);
    exit;
}

$account = (string)($req['account'] ?? '');
if (!preg_match('/^[0-9a-f]{64}$/', $account)) fail(400, 'ungültige Konto-Kennung');
$since = (int)($req['since'] ?? 0);
$in = is_array($req['items'] ?? null) ? $req['items'] : [];

// Konto prüfen
$allowedFile = "$dir/allowed.txt";
if (LOCK_TO_FIRST_ACCOUNT) {
    $fh = fopen($allowedFile, 'c+');
    if ($fh === false) fail(500, 'allowed.txt nicht schreibbar');
    flock($fh, LOCK_EX);
    $allowed = array_filter(array_map('trim', explode("\n", stream_get_contents($fh) ?: '')));
    if (!$allowed) {
        fwrite($fh, $account . "\n");
        $allowed = [$account];
    }
    flock($fh, LOCK_UN);
    fclose($fh);
    if (!in_array($account, $allowed, true)) fail(403, 'Dieser Server gehört einem anderen Sync-Passwort');
}

// Eingehende Elemente prüfen
$items = [];
$sent = [];
foreach ($in as $it) {
    if (!is_array($it)) continue;
    $k = (string)($it['k'] ?? '');
    if ($k === '' || strlen($k) > 300) continue;
    $t = (int)($it['t'] ?? 0);
    $d = !empty($it['d']) ? 1 : 0;
    $b = $d ? '' : (string)($it['b'] ?? '');
    $items[] = [$k, $t, $d, $b];
    $sent[$k] = $t;
}

$out = [];
$seq = 0;
if (extension_loaded('pdo_sqlite')) {
    try {
        $db = new PDO('sqlite:' . $dir . '/' . $account . '.sqlite');
        $db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $db->setAttribute(PDO::ATTR_TIMEOUT, 30);
        $db->exec('CREATE TABLE IF NOT EXISTS items (k TEXT PRIMARY KEY, t INTEGER NOT NULL, d INTEGER NOT NULL, b TEXT NOT NULL, s INTEGER NOT NULL)');
        $db->exec('CREATE INDEX IF NOT EXISTS items_s ON items(s)');
        $db->exec('CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY, v INTEGER NOT NULL)');
        $db->exec('BEGIN IMMEDIATE');
        $seq = (int)($db->query("SELECT v FROM meta WHERE name = 'seq'")->fetchColumn() ?: 0);
        $get = $db->prepare('SELECT t FROM items WHERE k = ?');
        $put = $db->prepare('INSERT OR REPLACE INTO items (k, t, d, b, s) VALUES (?, ?, ?, ?, ?)');
        foreach ($items as [$k, $t, $d, $b]) {
            $get->execute([$k]);
            $cur = $get->fetchColumn();
            if ($cur === false || $t > (int)$cur) {
                $seq++;
                $put->execute([$k, $t, $d, $b, $seq]);
            }
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
        if (isset($db) && $db->inTransaction()) $db->exec('ROLLBACK');
        fail(500, 'Datenbankfehler: ' . $e->getMessage());
    }
} else {
    // Ersatz ohne SQLite: eine JSON-Datei pro Konto, mit Dateisperre
    $file = "$dir/$account.json";
    $fh = fopen($file, 'c+');
    if ($fh === false) fail(500, 'Datendatei nicht schreibbar');
    flock($fh, LOCK_EX);
    $data = json_decode(stream_get_contents($fh) ?: '', true) ?: ['seq' => 0, 'items' => []];
    $seq = (int)$data['seq'];
    foreach ($items as [$k, $t, $d, $b]) {
        $cur = $data['items'][$k] ?? null;
        if ($cur === null || $t > (int)$cur['t']) {
            $seq++;
            $data['items'][$k] = ['k' => $k, 't' => $t, 'd' => (bool)$d, 'b' => $b, 's' => $seq];
        }
    }
    $data['seq'] = $seq;
    ftruncate($fh, 0);
    rewind($fh);
    fwrite($fh, json_encode($data));
    fflush($fh);
    flock($fh, LOCK_UN);
    fclose($fh);
    foreach ($data['items'] as $r) {
        if ($r['s'] <= $since) continue;
        if (isset($sent[$r['k']]) && $sent[$r['k']] === (int)$r['t']) continue;
        $out[] = $r;
    }
}

echo json_encode(['seq' => $seq, 'items' => $out], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
