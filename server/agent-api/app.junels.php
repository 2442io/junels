<?php
/**
 * App-Profil der Weiche für die Junels Agent-API – als data/app.php speichern
 * (bleibt beim Ersetzen von weiche/ erhalten).
 */
return [
    'name'          => 'junels',
    'domain'        => 'agent.2442.io',
    'prefix'        => 'JUNELS',                // Konstanten JUNELS_CHANNEL, JUNELS_STORAGE … und Cookies junels_*
    'health_path'   => '/_junels/health',
    'assets_dir'    => 'app/assets',
    'path_style'    => 'plain',                 // Kanal-Pfade /q/, /t/ (zusätzlich /_q/, /_t/)

    'version_file'  => 'app/index.php',
    'version_regex' => "/define\\('JUNELS_API_VERSION',\\s*'(\\d+)'\\)/",
    'zip_example'   => 'junels-api_v5.zip',

    'health_file'   => 'app/health.php',
    'health_boot'   => 'app/health.php',
    'migrations'    => 'app/migrations/[0-9][0-9][0-9][0-9]_*.php',

    'zip_skip'      => '#^(\.env$|\.sso/|storage/.+)#',

    // Abnahme: Proben gegen den laufenden Kanal (ohne Anmeldung, wie ein fremder Besucher)
    'live_max_ms' => 1500,
    'live_probes' => [
        ['name' => 'Info (JSON)', 'path' => '/', 'status' => [200], 'json' => true],
        ['name' => 'Abgleich ohne Anmeldung abgelehnt', 'method' => 'POST', 'path' => '/sync', 'status' => [400, 401], 'json' => true, 'deny' => true],
        ['name' => 'Daten löschen ohne Anmeldung abgelehnt', 'method' => 'POST', 'path' => '/wipe', 'status' => [400, 401], 'json' => true, 'deny' => true],
        ['name' => 'Übersicht ohne Anmeldung abgelehnt', 'method' => 'POST', 'path' => '/status', 'status' => [400, 401], 'json' => true, 'deny' => true],
    ],

    'maintenance_de' => 'Wir machen gerade ein Update. Deine Daten bleiben verschlüsselt und sicher.',
    'maintenance_en' => 'We are rolling out an update. Your data stays encrypted and safe.',
];
