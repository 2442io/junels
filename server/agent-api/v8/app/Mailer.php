<?php
/**
 * Junels – E-Mail-Versand. Wie in den anderen Projekten über SMTP aus der env:
 *   MAIL_HOST, MAIL_PORT, MAIL_USER, MAIL_PASS, MAIL_FROM, MAIL_FROM_NAME, MAIL_ENCRYPTION (ssl|tls|none)
 * Port 465 = SSL von Anfang an, 587 = STARTTLS. Ohne MAIL_HOST: PHP mail().
 */
declare(strict_types=1);

final class Mailer
{
    /** Wert aus der env – als Konstante (JUNELS_X oder X), Umgebungsvariable oder $_ENV/$_SERVER */
    public static function env(string $k, string $def = ''): string
    {
        foreach (['JUNELS_' . $k, $k] as $c) if (defined($c)) return (string)constant($c);
        $v = getenv($k);
        if ($v !== false && $v !== '') return (string)$v;
        $v = $_ENV[$k] ?? $_SERVER[$k] ?? null;
        if ($v !== null && $v !== '') return (string)$v;
        return self::fileEnv()[$k] ?? $def;
    }

    private static ?array $file = null;
    public static string $envSource = '';

    /** .env-Dateien selbst lesen (falls die Weiche sie nicht als Umgebung setzt): Version, Kanal, Wurzel */
    public static function fileEnv(): array
    {
        if (self::$file !== null) return self::$file;
        $channel = defined('JUNELS_CHANNEL') ? strtolower((string)JUNELS_CHANNEL) : 'prod';
        $names = ['.env', "env/$channel.env", 'env/prod.env', "shared/$channel/.env"];
        $out = [];
        $dir = __DIR__;
        for ($i = 0; $i < 6 && $dir !== '' && $dir !== '/'; $i++) {
            foreach ($names as $n) {
                $f = "$dir/$n";
                if (!is_file($f) || !is_readable($f)) continue;
                foreach (file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
                    $line = trim($line);
                    if ($line === '' || $line[0] === '#' || !str_contains($line, '=')) continue;
                    [$key, $val] = array_map('trim', explode('=', $line, 2));
                    if (str_starts_with($key, 'export ')) $key = trim(substr($key, 7));
                    if (strlen($val) >= 2 && ($val[0] === '"' || $val[0] === "'") && substr($val, -1) === $val[0]) $val = substr($val, 1, -1);
                    if (!isset($out[$key])) $out[$key] = $val;
                }
                if (isset($out['MAIL_HOST']) && self::$envSource === '') self::$envSource = $f;
            }
            $dir = dirname($dir);
        }
        return self::$file = $out;
    }

    /** Für die Fehlersuche: welche Einstellungen gefunden wurden (ohne Passwort) */
    public static function describe(): string
    {
        $host = self::env('MAIL_HOST');
        if ($host === '') return 'kein MAIL_HOST gefunden – Versand über PHP mail()';
        self::fileEnv();
        return 'SMTP ' . $host . ':' . (self::env('MAIL_PORT') ?: '465') . ' (' . (self::env('MAIL_ENCRYPTION', 'tls') ?: 'tls') . '), Benutzer '
            . (self::env('MAIL_USER') ?: '–') . ', Passwort ' . (self::env('MAIL_PASS') !== '' ? 'gesetzt' : 'fehlt')
            . ', Absender ' . (self::env('MAIL_FROM') ?: '–') . (self::$envSource !== '' ? ' · aus ' . basename(dirname(self::$envSource)) . '/' . basename(self::$envSource) : '');
    }

    /** Schickt eine Text-Mail; false bei Fehler (Grund in $error, ohne Passwort) */
    public static function send(string $to, string $subject, string $text, ?string &$error = null, string $fallbackFrom = ''): bool
    {
        $from = self::env('MAIL_FROM', $fallbackFrom);
        $name = self::env('MAIL_FROM_NAME', 'Junels');
        $subj = '=?UTF-8?B?' . base64_encode($subject) . '?=';
        $fromHdr = '=?UTF-8?B?' . base64_encode($name) . '?= <' . $from . '>';
        $host = self::env('MAIL_HOST');
        if ($host === '') {
            $ok = @mail($to, $subj, $text, "From: $fromHdr\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\nMIME-Version: 1.0");
            if (!$ok) $error = 'PHP mail() fehlgeschlagen – MAIL_HOST in der env eintragen (SMTP)';
            return $ok;
        }
        try {
            self::smtp($host, (int)(self::env('MAIL_PORT') ?: '465'), strtolower(self::env('MAIL_ENCRYPTION', 'tls')),
                self::env('MAIL_USER'), self::env('MAIL_PASS'), $from, $to,
                "Date: " . date('r') . "\r\nFrom: $fromHdr\r\nTo: <$to>\r\nSubject: $subj\r\n"
                . "Message-ID: <" . bin2hex(random_bytes(12)) . '@' . (explode('@', $from)[1] ?? 'junels') . ">\r\n"
                . "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                . chunk_split(base64_encode($text)));
            return true;
        } catch (Throwable $e) {
            $error = $e->getMessage();
            return false;
        }
    }

    private static function smtp(string $host, int $port, string $enc, string $user, string $pass, string $from, string $to, string $data): void
    {
        $ctx = stream_context_create(['ssl' => ['peer_name' => $host, 'verify_peer' => true, 'verify_peer_name' => true]]);
        $implicit = $port === 465 || $enc === 'ssl' || $enc === 'smtps';
        $s = @stream_socket_client(($implicit ? 'ssl://' : 'tcp://') . "$host:$port", $no, $msg, 15, STREAM_CLIENT_CONNECT, $ctx);
        if (!$s) throw new RuntimeException("SMTP: keine Verbindung zu $host:$port ($msg)");
        stream_set_timeout($s, 20);
        $read = function () use ($s): array {
            $all = '';
            while (($l = fgets($s, 1024)) !== false) { $all .= $l; if (strlen($l) < 4 || $l[3] !== '-') break; }
            return [(int)substr($all, 0, 3), trim($all)];
        };
        $cmd = function (string $c, array $okCodes, string $show = '') use ($s, $read): string {
            fwrite($s, $c . "\r\n");
            [$code, $resp] = $read();
            if (!in_array($code, $okCodes, true)) throw new RuntimeException('SMTP ' . ($show ?: strtok($c, ' ')) . ': ' . $resp);
            return $resp;
        };
        [$code, $resp] = $read();
        if ($code !== 220) throw new RuntimeException('SMTP Begrüßung: ' . $resp);
        $me = (string)($_SERVER['SERVER_NAME'] ?? 'localhost');
        $ehlo = $cmd("EHLO $me", [250]);
        if (!$implicit && $enc !== 'none' && $enc !== '') {
            $cmd('STARTTLS', [220]);
            if (!stream_socket_enable_crypto($s, true, STREAM_CRYPTO_METHOD_TLSv1_2_CLIENT | STREAM_CRYPTO_METHOD_TLSv1_3_CLIENT))
                throw new RuntimeException('SMTP: TLS fehlgeschlagen');
            $ehlo = $cmd("EHLO $me", [250]);
        }
        if ($user !== '') {
            if (stripos($ehlo, 'PLAIN') !== false) {
                $cmd('AUTH PLAIN ' . base64_encode("\0$user\0$pass"), [235], 'Anmeldung');
            } else {
                $cmd('AUTH LOGIN', [334]);
                $cmd(base64_encode($user), [334], 'Anmeldung');
                $cmd(base64_encode($pass), [235], 'Anmeldung');
            }
        }
        $cmd("MAIL FROM:<$from>", [250]);
        $cmd("RCPT TO:<$to>", [250, 251]);
        $cmd('DATA', [354]);
        $cmd(preg_replace('/^\./m', '..', $data) . "\r\n.", [250], 'Senden');
        @fwrite($s, "QUIT\r\n");
        fclose($s);
    }
}
