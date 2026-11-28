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
        return (string)($_ENV[$k] ?? $_SERVER[$k] ?? $def);
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
            if (!$ok) $error = 'mail() fehlgeschlagen';
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
