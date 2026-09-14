<?php
// Mail transport (NOT-02 email channel, NOT-04 digest). Pure PHP, no HTTP.
//
//   mail_transport()                                   -> 'smtp' | 'php_mail' | null
//   mail_send($to, $subject, $text, $html, $inApp?)    -> ['sent' => bool, 'transport' => ..., 'reason' => ..., 'in_app' => bool, 'notification_id' => ...]
//
// Honesty is the point of this file. There is no SMTP server on the box this was built on,
// and a "sent" that nobody received is worse than an in-app copy that everybody can read.
// So the return value states what actually happened: `sent` is true only when a transport
// accepted the message; when none is configured — or the one that is fails — the message
// is written to dbo.notifications as kind `digest` for the recipient instead, `in_app` says
// so and `reason` says why. Callers must report both facts and never collapse them into
// "emailed".
//
// Configuration (api/config.php, all optional — see config.example.php):
//   'smtp' => ['host','port','secure' ('tls'|'ssl'|'none'),'user','pass','from','from_name','timeout']
//   'mail' => ['php_mail' => true]      use PHP's mail() (php.ini sendmail_path / SMTP) instead
// `smtp.host` wins when both are present.
require_once __DIR__ . '/../lib.php';

/** Which transport the configuration selects, or null for none. */
function mail_transport() {
    $cfg = dp_config();
    if (!empty($cfg['smtp']['host'])) return 'smtp';
    if (!empty($cfg['mail']['php_mail'])) return 'php_mail';
    return null;
}

/**
 * Send one message.
 *
 * @param string|null $to     recipient address; null/empty means "cannot be emailed" and goes straight to the in-app path
 * @param array|null  $inApp  ['conn' => $conn, 'workspace_id' => int, 'user_id' => int, 'body' => short summary (<=600 chars), 'link' => app route]
 *                            When given and the mail path did not deliver, the message lands as an in-app notification of kind
 *                            `digest`, honouring that user's in-app switch for the kind (in-app off => nothing is written, and the
 *                            result says so).
 */
function mail_send($to, $subject, $text, $html, array $inApp = null) {
    $transport = mail_transport();
    $r = ['sent' => false, 'transport' => $transport, 'to' => $to, 'reason' => null, 'in_app' => false, 'notification_id' => null];
    $to = trim((string)$to);
    if ($transport === null) {
        $r['reason'] = 'no mail transport configured';
    } elseif ($to === '' || !filter_var($to, FILTER_VALIDATE_EMAIL)) {
        $r['reason'] = 'recipient has no valid email address';
    } else {
        $cfg = dp_config();
        [$ok, $why] = $transport === 'smtp' ? smtp_deliver($cfg['smtp'], $to, $subject, $text, $html) : php_mail_deliver($cfg, $to, $subject, $text, $html);
        $r['sent'] = $ok; $r['reason'] = $why;
        if ($ok) return $r;
    }
    // In-app fallback: a digest that cannot be mailed is still a digest.
    if ($inApp !== null && isset($inApp['conn'], $inApp['workspace_id'], $inApp['user_id'])) {
        $pref = notification_pref($inApp['conn'], (int)$inApp['user_id'], 'digest');
        if (!$pref['in_app']) {
            $r['reason'] = ($r['reason'] ? $r['reason'] . '; ' : '') . 'in-app digest is turned off for this user';
        } else {
            $r['notification_id'] = insert($inApp['conn'], 'notifications', ['workspace_id' => (int)$inApp['workspace_id'], 'user_id' => (int)$inApp['user_id'], 'kind' => 'digest',
                'title' => mb_substr((string)$subject, 0, 200), 'body' => mb_substr((string)($inApp['body'] ?? $text), 0, 600),
                'link' => $inApp['link'] ?? null, 'urgent' => 0, 'channel' => 'in_app']);
            $r['in_app'] = true;
        }
    }
    return $r;
}

// ---- transports -------------------------------------------------------------------------------

/** Bare address out of "Name <addr>" or "addr". */
function mail_addr($s) { return preg_match('/<([^>]+)>/', (string)$s, $m) ? trim($m[1]) : trim((string)$s); }
function mail_encode_header($s) { return preg_match('/[^\x20-\x7e]/', (string)$s) ? '=?UTF-8?B?' . base64_encode((string)$s) . '?=' : (string)$s; }

/** MIME headers + body for a multipart/alternative message. Returns [headers-string-without-To/Subject, body, boundary]. */
function mail_mime_parts($text, $html) {
    $b = 'dp' . bin2hex(random_bytes(12));
    $nl = "\r\n";
    $body = "--$b$nl" . "Content-Type: text/plain; charset=UTF-8$nl" . "Content-Transfer-Encoding: base64$nl$nl" . chunk_split(base64_encode((string)$text)) . $nl
          . "--$b$nl" . "Content-Type: text/html; charset=UTF-8$nl" . "Content-Transfer-Encoding: base64$nl$nl" . chunk_split(base64_encode((string)$html)) . $nl
          . "--$b--$nl";
    $headers = "MIME-Version: 1.0$nl" . "Content-Type: multipart/alternative; boundary=\"$b\"$nl" . "X-Mailer: Dispatch$nl";
    return [$headers, $body, $b];
}

/** PHP mail(): whatever php.ini's sendmail_path / SMTP points at. Returns [ok, reason]. */
function php_mail_deliver(array $cfg, $to, $subject, $text, $html) {
    if (!function_exists('mail')) return [false, 'mail() is not available in this PHP build'];
    [$headers, $body] = mail_mime_parts($text, $html);
    $from = $cfg['mail']['from'] ?? ($cfg['smtp']['from'] ?? null);
    if ($from) $headers .= 'From: ' . mail_encode_header($cfg['mail']['from_name'] ?? 'Dispatch') . " <" . mail_addr($from) . ">\r\n";
    $lastErr = null;
    set_error_handler(function ($no, $str) use (&$lastErr) { $lastErr = $str; return true; });
    try { $ok = mail($to, mail_encode_header($subject), $body, $headers); }
    finally { restore_error_handler(); }
    return [$ok === true, $ok === true ? null : 'mail() refused the message' . ($lastErr ? ": $lastErr" : '')];
}

/**
 * A minimal SMTP client (EHLO, STARTTLS, AUTH LOGIN, one recipient). Enough for an Office 365 /
 * Exchange relay or a local Postfix; anything more exotic belongs in a proper library.
 * Returns [ok, reason]. Never throws.
 */
function smtp_deliver(array $s, $to, $subject, $text, $html) {
    $host = (string)$s['host']; $port = (int)($s['port'] ?? 587);
    $secure = strtolower((string)($s['secure'] ?? ($port === 465 ? 'ssl' : ($port === 587 ? 'tls' : 'none'))));
    $timeout = max(3, (int)($s['timeout'] ?? 15));
    $from = mail_addr($s['from'] ?? ('dispatch@' . (gethostname() ?: 'localhost')));
    $fromName = $s['from_name'] ?? 'Dispatch';
    $fp = @stream_socket_client(($secure === 'ssl' ? 'ssl://' : 'tcp://') . "$host:$port", $errno, $errstr, $timeout);
    if (!$fp) return [false, "SMTP connect to $host:$port failed: $errstr"];
    stream_set_timeout($fp, $timeout);
    $read = function () use ($fp) { $out = ''; while (($line = fgets($fp, 1024)) !== false) { $out .= $line; if (strlen($line) < 4 || $line[3] !== '-') break; } return $out; };
    $cmd = function ($c, $expect) use ($fp, $read) {
        if ($c !== null) fwrite($fp, $c . "\r\n");
        $reply = $read(); $code = (int)substr($reply, 0, 3);
        if (!in_array($code, (array)$expect, true)) throw new RuntimeException(($c !== null ? preg_replace('/^(AUTH LOGIN|[A-Za-z0-9+\/=]{8,})$/', '<credentials>', $c) . ' -> ' : '') . trim($reply ?: 'no reply'));
        return $reply;
    };
    try {
        $me = gethostname() ?: 'localhost';
        $cmd(null, 220);
        $cmd("EHLO $me", 250);
        if ($secure === 'tls') {
            $cmd('STARTTLS', 220);
            if (!@stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) throw new RuntimeException('STARTTLS negotiation failed');
            $cmd("EHLO $me", 250);
        }
        if (!empty($s['user'])) { $cmd('AUTH LOGIN', 334); $cmd(base64_encode((string)$s['user']), 334); $cmd(base64_encode((string)($s['pass'] ?? '')), 235); }
        $cmd("MAIL FROM:<$from>", 250);
        $cmd("RCPT TO:<" . mail_addr($to) . ">", [250, 251]);
        $cmd('DATA', 354);
        [$mimeHeaders, $body] = mail_mime_parts($text, $html);
        $nl = "\r\n";
        $msg = 'From: ' . mail_encode_header($fromName) . " <$from>$nl" . "To: <" . mail_addr($to) . ">$nl" . 'Subject: ' . mail_encode_header($subject) . $nl
             . 'Date: ' . date(DATE_RFC2822) . $nl . 'Message-ID: <' . bin2hex(random_bytes(8)) . '@' . $me . ">$nl" . $mimeHeaders . $nl . $body;
        fwrite($fp, preg_replace('/^\./m', '..', $msg) . "$nl.$nl");
        $cmd(null, 250);
        fwrite($fp, "QUIT\r\n");
        fclose($fp);
        return [true, null];
    } catch (RuntimeException $e) {
        @fclose($fp);
        return [false, 'SMTP: ' . $e->getMessage()];
    }
}
