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
 */
declare(strict_types=1);

const MAX_BODY = 64 * 1024 * 1024;   // größte Anfrage (Bytes)
const LOCK_TO_FIRST_ACCOUNT = true; // nur das erste Konto zulassen

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
    echo json_encode(['ok' => true, 'app' => 'junels-sync', 'v' => 1,
        'storage' => extension_loaded('pdo_sqlite') ? 'sqlite' : 'json']);
    exit;
}
if ($method !== 'POST') fail(405, 'nur POST');

$raw = file_get_contents('php://input', false, null, 0, MAX_BODY + 1);
if ($raw === false || strlen($raw) > MAX_BODY) fail(413, 'Anfrage zu groß');
$req = json_decode($raw, true);
if (!is_array($req)) fail(400, 'kein gültiges JSON');

$account = (string)($req['account'] ?? '');
if (!preg_match('/^[0-9a-f]{64}$/', $account)) fail(400, 'ungültige Konto-Kennung');
$since = (int)($req['since'] ?? 0);
$in = is_array($req['items'] ?? null) ? $req['items'] : [];

$dir = __DIR__ . '/junels-data';
if (!is_dir($dir) && !@mkdir($dir, 0700, true)) fail(500, 'Datenordner kann nicht angelegt werden (Schreibrechte?)');
if (!file_exists("$dir/.htaccess")) {
    file_put_contents("$dir/.htaccess", "Require all denied\n<IfModule !mod_authz_core.c>\nDeny from all\n</IfModule>\n");
}
if (!file_exists("$dir/index.html")) file_put_contents("$dir/index.html", '');

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
