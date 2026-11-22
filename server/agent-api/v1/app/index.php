<?php
/**
 * Junels Agent-API – Router (nur Klar-URLs, keine Parameter).
 */
declare(strict_types=1);
define('JUNELS_API_VERSION', '1');

require __DIR__ . '/Api.php';

$base = defined('JUNELS_BASE') ? (string)JUNELS_BASE : '';
$uri = (string)parse_url((string)($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$path = ($base !== '' && str_starts_with($uri, $base)) ? substr($uri, strlen($base)) : $uri;
if ($path === '' || $path[0] !== '/') $path = '/' . $path;
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

Api::headers();
try {
    if ($path === '/_junels/health') {
        require __DIR__ . '/health.php';
        Api::json(Health::check(false, false));
    } elseif ($path === '/' && $method === 'GET') {
        Api::json(['ok' => true, 'app' => 'junels-api', 'v' => (int)JUNELS_API_VERSION, 'sso' => Api::ssoReady()]);
    } elseif ($path === '/login' && $method === 'GET') {
        Api::loginInfo();
    } elseif (preg_match('#^/login/(\d{4,5})$#', $path, $m) && $method === 'GET') {
        Api::login((int)$m[1], $base . $path);
    } elseif (in_array($path, ['/sync', '/whoami', '/logout', '/wipe'], true)) {
        if ($method !== 'POST') Api::fail(405, 'nur POST');
        Api::post(substr($path, 1));
    } else {
        Api::fail(404, 'Nicht gefunden');
    }
} catch (Throwable $e) {
    if (class_exists('Weiche')) Weiche::log('[junels-api] ' . $e->getMessage());
    Api::fail(500, 'Interner Fehler');
}
