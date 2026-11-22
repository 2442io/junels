<?php
// Cron je Kanal (php cron.php prod): alte App-Anmeldungen (> 180 Tage unbenutzt) aufräumen.
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require __DIR__ . '/app/Api.php';
$n = Api::cleanupTokens(180);
echo "Junels Agent-API: $n alte Anmeldungen entfernt\n";
