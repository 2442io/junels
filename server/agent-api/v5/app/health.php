<?php
/**
 * Gesundheits-Check (Weiche: vor dem Umschalten mit $full; Monitoring: /_junels/health).
 */
declare(strict_types=1);
require_once __DIR__ . '/Api.php';

final class Health
{
    public static function check(bool $full = false, bool $migrate = false): array
    {
        $errors = [];
        $warnings = [];
        if (PHP_VERSION_ID < 80100) $errors[] = 'PHP 8.1 oder neuer nötig (läuft: ' . PHP_VERSION . ')';
        foreach (['pdo_sqlite', 'json', 'openssl'] as $ext) if (!extension_loaded($ext)) $errors[] = "PHP-Erweiterung $ext fehlt";
        if (!extension_loaded('curl') && !ini_get('allow_url_fopen')) $errors[] = 'Für SSO: curl oder allow_url_fopen nötig';
        $root = defined('JUNELS_STORAGE') ? (string)JUNELS_STORAGE : '';
        if ($root === '') $warnings[] = 'Läuft ohne Weiche (kein Kanal-Speicher)';
        elseif (!is_dir($root) || !is_writable($root)) $errors[] = 'Kanal-Speicher nicht beschreibbar';
        if (!Api::ssoReady()) $warnings[] = 'SSO-Client nicht gefunden';
        elseif ($full && defined('JUNELS_SSO_STATE') && !is_file(rtrim((string)JUNELS_SSO_STATE, '/') . '/config.php')) {
            $warnings[] = 'SSO für diesen Kanal noch nicht gekoppelt – einmal …/login im Browser öffnen';
        }
        return ['ok' => !$errors, 'version' => (int)JUNELS_API_VERSION, 'channel' => defined('JUNELS_CHANNEL') ? JUNELS_CHANNEL : null,
            'errors' => $errors, 'warnings' => $warnings, 'schema' => ['ran' => []]];
    }
}
if (!defined('JUNELS_API_VERSION')) define('JUNELS_API_VERSION', '1');
