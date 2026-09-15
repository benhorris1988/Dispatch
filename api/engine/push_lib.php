<?php
// Push notifications (MOB-04). Pure PHP, no HTTP entry point of its own.
//
// Two halves, queued like webhooks:
//   push_queue()    — called from lib.php notify(): one dbo.push_deliveries row per active device
//                     the recipient has registered through devices.php. Never fails the caller.
//   push_dispatch() — sends what is due through FCM HTTP v1 (Android, web) or APNs (iOS) when
//                     the sender is configured in api/config.php under 'push'. When it is not,
//                     the row is marked 'unconfigured' with the reason in last_status. A row is
//                     only ever 'sent' after the provider answered 2xx.
//
// config.php keys (all optional; see config.example.php):
//   push.fcm_service_account_json   path to a Firebase service-account JSON file, or the JSON itself
//   push.apns_key_file              path to the APNs auth key (.p8)
//   push.apns_key_id                the key's id (10 characters)
//   push.apns_team_id               Apple developer team id
//   push.apns_bundle_id             defaults to uk.co.dispatch.app
//   push.apns_sandbox               true to use api.sandbox.push.apple.com (development builds)

/** Back-off between attempts, in seconds: ~1m, 5m, 30m, then abandon — a push older than that is stale. */
const DP_PUSH_BACKOFF = [60, 300, 1800];

const DP_PUSH_PLATFORMS = ['ios', 'android', 'web'];

/** Which sender a device platform uses. */
function push_sender_for($platform) { return $platform === 'ios' ? 'apns' : 'fcm'; }

/**
 * What is configured, and — when something is not — the exact sentence that goes into
 * last_status so an operator reading the table knows which key to set.
 */
function push_config() {
    static $c = null;
    if ($c !== null) return $c;
    $cfg = dp_config()['push'] ?? [];
    $c = ['fcm' => false, 'apns' => false, 'reasons' => [], 'fcm_project' => null];
    $sa = push_fcm_service_account($cfg);
    if ($sa === null) {
        $c['reasons']['fcm'] = 'No FCM sender configured: set push.fcm_service_account_json in api/config.php to a Firebase service-account JSON file.';
    } elseif (empty($sa['client_email']) || empty($sa['private_key']) || empty($sa['project_id'])) {
        $c['reasons']['fcm'] = 'push.fcm_service_account_json is not a Firebase service-account file (needs client_email, private_key and project_id).';
    } else {
        $c['fcm'] = true;
        $c['fcm_project'] = $sa['project_id'];
    }
    $missing = [];
    foreach (['apns_key_file', 'apns_key_id', 'apns_team_id'] as $k) if (empty($cfg[$k])) $missing[] = "push.$k";
    if ($missing) {
        $c['reasons']['apns'] = 'No APNs sender configured: set ' . implode(', ', $missing) . ' in api/config.php.';
    } elseif (!is_readable($cfg['apns_key_file'])) {
        $c['reasons']['apns'] = 'push.apns_key_file is not readable: ' . $cfg['apns_key_file'];
    } else {
        $c['apns'] = true;
    }
    return $c;
}

/** The decoded service account, from a path or an inline JSON string; null when unset. */
function push_fcm_service_account(array $cfg) {
    $v = $cfg['fcm_service_account_json'] ?? null;
    if ($v === null || $v === '') return null;
    if (is_array($v)) return $v;
    $raw = (strlen($v) < 1024 && is_readable($v)) ? file_get_contents($v) : $v;
    $j = json_decode((string)$raw, true);
    return is_array($j) ? $j : [];
}

/**
 * Queue a push to every active device the user has registered.
 *
 * Best-effort in the strongest sense: a notification must never fail to be written because
 * the push queue could not be. fail() is turned into an exception for the duration and
 * swallowed, exactly as start_urgent_cycle does.
 *
 * @return int rows queued (0 when the user has no device, or on error)
 */
function push_queue($conn, $wsId, $userId, $title, $body, $link, $notificationId) {
    if ($userId === null || $userId === '') return 0;
    $prev = $GLOBALS['dp_soft_fail'] ?? false;
    $GLOBALS['dp_soft_fail'] = true;
    try {
        $devices = rows($conn, "SELECT id FROM dbo.device_tokens WHERE workspace_id = ? AND user_id = ? AND active = 1", [$wsId, $userId]);
        $n = 0;
        foreach ($devices as $d) {
            insert($conn, 'push_deliveries', ['workspace_id' => $wsId, 'notification_id' => $notificationId, 'device_token_id' => (int)$d['id'],
                'title' => mb_substr((string)$title, 0, 200), 'body' => $body === null ? null : mb_substr((string)$body, 0, 600),
                'link' => $link === null ? null : mb_substr((string)$link, 0, 200), 'status' => 'pending']);
            $n++;
        }
        return $n;
    } catch (Throwable $e) {
        error_log('push_queue failed (the notification itself is unaffected): ' . $e->getMessage());
        return 0;
    } finally {
        $GLOBALS['dp_soft_fail'] = $prev;
    }
}

/**
 * Send what is due for a workspace. Returns counts; never throws.
 *
 * A provider saying the token is dead (FCM UNREGISTERED, APNs 410 / BadDeviceToken) deactivates
 * the device row so nothing else is queued to it. Any other failure backs off and retries;
 * after the ladder is exhausted the row is 'abandoned'.
 */
function push_dispatch($conn, $wsId, $limit = 50) {
    $limit = max(1, (int)$limit);
    $conf = push_config();
    $due = rows($conn, "SELECT TOP ($limit) d.*, t.platform, t.token, t.active AS device_active FROM dbo.push_deliveries d
        JOIN dbo.device_tokens t ON t.id = d.device_token_id
        WHERE d.workspace_id = ? AND d.status IN ('pending','failed') AND d.next_attempt_at <= SYSDATETIME()
        ORDER BY d.id", [$wsId]);
    $out = ['due' => count($due), 'sent' => 0, 'failed' => 0, 'abandoned' => 0, 'unconfigured' => 0];
    foreach ($due as $d) {
        $id = (int)$d['id'];
        $attempt = (int)$d['attempts'] + 1;
        if (!(int)$d['device_active']) {
            update($conn, 'push_deliveries', ['status' => 'abandoned', 'attempts' => $attempt, 'last_status' => 'Device unregistered before the push was sent.'], 'id = ?', [$id]);
            $out['abandoned']++;
            continue;
        }
        $sender = push_sender_for($d['platform']);
        if (empty($conf[$sender])) {
            update($conn, 'push_deliveries', ['status' => 'unconfigured', 'last_status' => mb_substr($conf['reasons'][$sender], 0, 200)], 'id = ?', [$id]);
            $out['unconfigured']++;
            continue;
        }
        [$sent, $status, $deadToken] = $sender === 'apns'
            ? push_send_apns($d['token'], $d['title'], $d['body'], $d['link'], $d['notification_id'])
            : push_send_fcm($conf['fcm_project'], $d['token'], $d['title'], $d['body'], $d['link'], $d['notification_id'], $d['platform']);
        $status = mb_substr($status, 0, 200);
        if ($sent) {
            update($conn, 'push_deliveries', ['status' => 'sent', 'attempts' => $attempt, 'sent_at' => date('Y-m-d H:i:s'), 'last_status' => $status], 'id = ?', [$id]);
            $out['sent']++;
            continue;
        }
        if ($deadToken) {
            update($conn, 'device_tokens', ['active' => 0], 'id = ?', [(int)$d['device_token_id']]);
            update($conn, 'push_deliveries', ['status' => 'abandoned', 'attempts' => $attempt, 'last_status' => $status], 'id = ?', [$id]);
            $out['abandoned']++;
            continue;
        }
        if ($attempt > count(DP_PUSH_BACKOFF)) {
            update($conn, 'push_deliveries', ['status' => 'abandoned', 'attempts' => $attempt, 'last_status' => $status], 'id = ?', [$id]);
            $out['abandoned']++;
        } else {
            $next = date('Y-m-d H:i:s', time() + DP_PUSH_BACKOFF[$attempt - 1]);
            update($conn, 'push_deliveries', ['status' => 'failed', 'attempts' => $attempt, 'next_attempt_at' => $next, 'last_status' => $status], 'id = ?', [$id]);
            $out['failed']++;
        }
    }
    return $out;
}

// ---- FCM HTTP v1 ------------------------------------------------------------------------

/**
 * OAuth2 access token for the service account (scope firebase.messaging), cached per process.
 * Signs a JWT with the account's RSA key and exchanges it at token_uri.
 */
function push_fcm_access_token() {
    static $cache = null;
    if ($cache !== null && $cache['expires'] > time() + 60) return $cache['token'];
    $sa = push_fcm_service_account(dp_config()['push'] ?? []);
    if (!$sa || empty($sa['private_key'])) return null;
    $now = time();
    $tokenUri = $sa['token_uri'] ?? 'https://oauth2.googleapis.com/token';
    $jwt = push_jws(['alg' => 'RS256', 'typ' => 'JWT'],
        ['iss' => $sa['client_email'], 'scope' => 'https://www.googleapis.com/auth/firebase.messaging', 'aud' => $tokenUri, 'iat' => $now, 'exp' => $now + 3600],
        $sa['private_key'], OPENSSL_ALGO_SHA256, false);
    if ($jwt === null) return null;
    [$code, $bodyRaw] = push_http('POST', $tokenUri, ['Content-Type: application/x-www-form-urlencoded'],
        http_build_query(['grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'assertion' => $jwt]));
    $j = json_decode((string)$bodyRaw, true);
    if ($code !== 200 || empty($j['access_token'])) return null;
    $cache = ['token' => $j['access_token'], 'expires' => $now + (int)($j['expires_in'] ?? 3600)];
    return $cache['token'];
}

/** @return array [sent, status, deadToken] */
function push_send_fcm($project, $token, $title, $body, $link, $notificationId, $platform) {
    $access = push_fcm_access_token();
    if ($access === null) return [false, 'FCM: could not obtain an access token for the service account', false];
    $data = ['link' => (string)($link ?? ''), 'notification_id' => (string)($notificationId ?? '')];
    $message = ['token' => $token, 'notification' => ['title' => $title, 'body' => (string)($body ?? '')], 'data' => $data];
    if ($platform === 'web') {
        $message['webpush'] = ['fcm_options' => ['link' => push_web_url($link)]];
    } else {
        $message['android'] = ['priority' => 'high', 'notification' => ['channel_id' => 'dispatch_default']];
    }
    $payload = json_encode(['message' => $message], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    [$code, $raw] = push_http('POST', "https://fcm.googleapis.com/v1/projects/$project/messages:send",
        ['Content-Type: application/json', "Authorization: Bearer $access"], $payload);
    if ($code >= 200 && $code < 300) return [true, "FCM HTTP $code", false];
    $j = json_decode((string)$raw, true);
    $status = $j['error']['status'] ?? '';
    $detail = $j['error']['message'] ?? ($code === 0 ? 'transport failure' : '');
    $dead = $code === 404 || $status === 'UNREGISTERED' || ($status === 'INVALID_ARGUMENT' && stripos($detail, 'token') !== false);
    return [false, trim("FCM HTTP $code $status: $detail"), $dead];
}

/** The https link a web push opens: the hosted web build's hash route for an app path. */
function push_web_url($link) {
    $base = rtrim(dp_config()['push']['web_base_url'] ?? '', '/');
    if ($base === '' || $link === null || $link === '') return $base === '' ? '/' : $base . '/';
    return $base . '/#' . $link;
}

// ---- APNs --------------------------------------------------------------------------------

/** Provider token (ES256), cached per process and renewed well inside Apple's one-hour limit. */
function push_apns_token() {
    static $cache = null;
    if ($cache !== null && $cache['issued'] > time() - 2400) return $cache['token'];
    $cfg = dp_config()['push'] ?? [];
    $key = @file_get_contents($cfg['apns_key_file']);
    if ($key === false) return null;
    $now = time();
    $jwt = push_jws(['alg' => 'ES256', 'kid' => $cfg['apns_key_id']], ['iss' => $cfg['apns_team_id'], 'iat' => $now], $key, OPENSSL_ALGO_SHA256, true);
    if ($jwt === null) return null;
    $cache = ['token' => $jwt, 'issued' => $now];
    return $jwt;
}

/** @return array [sent, status, deadToken] */
function push_send_apns($token, $title, $body, $link, $notificationId) {
    $cfg = dp_config()['push'] ?? [];
    $jwt = push_apns_token();
    if ($jwt === null) return [false, 'APNs: could not sign a provider token with push.apns_key_file', false];
    $host = !empty($cfg['apns_sandbox']) ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
    $topic = $cfg['apns_bundle_id'] ?? 'uk.co.dispatch.app';
    $payload = json_encode(['aps' => ['alert' => ['title' => $title, 'body' => (string)($body ?? '')], 'sound' => 'default'],
        'link' => (string)($link ?? ''), 'notification_id' => $notificationId], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    [$code, $raw] = push_http('POST', "https://$host/3/device/$token",
        ["authorization: bearer $jwt", "apns-topic: $topic", 'apns-push-type: alert', 'apns-priority: 10', 'content-type: application/json'], $payload, true);
    if ($code >= 200 && $code < 300) return [true, "APNs HTTP $code", false];
    $j = json_decode((string)$raw, true);
    $reason = $j['reason'] ?? ($code === 0 ? 'transport failure' : '');
    $dead = $code === 410 || in_array($reason, ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'], true);
    return [false, trim("APNs HTTP $code $reason"), $dead];
}

// ---- Shared ------------------------------------------------------------------------------

/**
 * Compact JWS. RS256 signatures are used as openssl returns them; ES256 needs the DER
 * ECDSA signature converted to the raw 64-byte R||S form the JWS spec requires.
 * Returns null if the key will not sign.
 */
function push_jws(array $header, array $claims, $pem, $algo, $ecdsa) {
    $b64 = fn($s) => rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
    $input = $b64(json_encode($header)) . '.' . $b64(json_encode($claims));
    $key = @openssl_pkey_get_private($pem);
    if ($key === false) return null;
    $sig = '';
    if (!@openssl_sign($input, $sig, $key, $algo)) return null;
    if ($ecdsa) $sig = push_der_to_raw($sig, 32);
    return $input . '.' . $b64($sig);
}

/** DER SEQUENCE{INTEGER r, INTEGER s} → fixed-width R||S. */
function push_der_to_raw($der, $width) {
    $pos = 2; // 0x30 len
    if (ord($der[1]) & 0x80) $pos += ord($der[1]) & 0x7f;
    $out = '';
    for ($i = 0; $i < 2; $i++) {
        $pos++; // 0x02
        $len = ord($der[$pos++]);
        $int = substr($der, $pos, $len);
        $pos += $len;
        $int = ltrim($int, "\0");
        $out .= str_pad($int, $width, "\0", STR_PAD_LEFT);
    }
    return $out;
}

/** One HTTPS request. Returns [http code (0 on transport failure), body]. Never throws. */
function push_http($method, $url, array $headers, $body, $http2 = false) {
    if (!function_exists('curl_init')) return [0, 'curl extension not available'];
    $ch = curl_init($url);
    $opts = [CURLOPT_CUSTOMREQUEST => $method, CURLOPT_POSTFIELDS => $body, CURLOPT_HTTPHEADER => $headers,
        CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15, CURLOPT_CONNECTTIMEOUT => 5];
    if ($http2 && defined('CURL_HTTP_VERSION_2_0')) $opts[CURLOPT_HTTP_VERSION] = CURL_HTTP_VERSION_2_0;
    curl_setopt_array($ch, $opts);
    $res = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err = curl_error($ch);
    curl_close($ch);
    if ($res === false || $code === 0) return [0, 'transport: ' . ($err ?: 'no response')];
    return [$code, $res];
}

/**
 * Dispatch every LIVE workspace, for the cron runner.
 *
 * Campaigns are skipped on purpose: a sandbox exists so people can try things, and a trial
 * reorganisation must not buzz somebody's phone at seven in the morning.
 */
function push_run_all($conn, $limit = 50) {
    $out = [];
    foreach (rows($conn, "SELECT id FROM dbo.workspaces WHERE ISNULL(kind, 'live') = 'live' ORDER BY id") as $w) {
        $out[] = ['workspace_id' => (int)$w['id']] + push_dispatch($conn, (int)$w['id'], $limit);
    }
    return $out;
}
