<?php
/**
 * Junels Agent-API – Router (nur Klar-URLs, keine Parameter).
 */
declare(strict_types=1);
define('JUNELS_API_VERSION', '7');

require __DIR__ . '/Api.php';
require __DIR__ . '/Site.php';
require __DIR__ . '/Mailer.php';

$base = defined('JUNELS_BASE') ? (string)JUNELS_BASE : '';
$uri = (string)parse_url((string)($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$path = ($base !== '' && str_starts_with($uri, $base)) ? substr($uri, strlen($base)) : $uri;
if ($path === '' || $path[0] !== '/') $path = '/' . $path;
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
// Die API liegt unter /api – die bisherigen Adressen ohne /api funktionieren weiter (ältere Apps)
$isApi = $path === '/api' || str_starts_with($path, '/api/');
if ($isApi) $path = substr($path, 4) ?: '/';
$html = str_contains((string)($_SERVER['HTTP_ACCEPT'] ?? ''), 'text/html');

Api::headers();
try {
    if ($path === '/_junels/health') {
        require __DIR__ . '/health.php';
        Api::json(Health::check(false, false));
    } elseif ($path === '/' && $method === 'GET' && $html) {
        // im Browser: Webseite mit allen Funktionen bzw. unter /api die Übersicht der Schnittstelle (Apps bekommen JSON)
        if ($isApi) Site::api($base);
        Site::home($base);
    } elseif ($path === '/' && $method === 'GET') {
        Api::json(['ok' => true, 'app' => 'junels-api', 'v' => (int)JUNELS_API_VERSION, 'sso' => Api::ssoReady()]);
    } elseif ($path === '/login' && $method === 'GET') {
        Api::loginInfo();
    } elseif (preg_match('#^/login/app/([0-9a-f]{64})$#', $path, $m) && $method === 'GET') {
        Api::loginApp($m[1], $base . $path);
    } elseif ($path === '/token') {
        if ($method !== 'POST') Api::fail(405, 'nur POST');
        Api::token();
    } elseif (preg_match('#^/login/(\d{4,5})$#', $path, $m) && $method === 'GET') {
        Api::login((int)$m[1], $base . $path);
    } elseif (in_array($path, ['/sync', '/whoami', '/logout', '/wipe', '/status'], true)) {
        if ($method !== 'POST') Api::fail(405, 'nur POST');
        Api::post(substr($path, 1));
    } elseif ($path === '/konto' && $method === 'GET') {
        // früher /konto (v3/v4) – jetzt /admin
        header('Location: ' . $base . '/admin', true, 301);
        exit;
    } elseif ($path === '/admin' && $method === 'GET') {
        Api::account($base . $path);
    } elseif (preg_match('#^/admin/bestaetigen/([0-9a-f]{64})$#', $path, $m)) {
        // Link aus der E-Mail: nur mit SSO-Anmeldung derselben Person; Zurücksetzen erst nach Klick (POST)
        Api::confirmReset($m[1], $base . $path, $method === 'POST');
    } elseif (preg_match('#^/admin/(zuruecksetzen|abmelden/[0-9a-f]{16}|geraet-entfernen/[0-9a-f]{8,64})$#', $path, $m) && $method === 'POST') {
        Api::accountAction($m[1], $base . '/admin');
    } else {
        Api::fail(404, 'Nicht gefunden');
    }
} catch (Throwable $e) {
    if (class_exists('Weiche')) Weiche::log('[junels-api] ' . $e->getMessage());
    Api::fail(500, 'Interner Fehler');
}
