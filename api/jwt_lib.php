<?php
require_once __DIR__ . '/lib.php';
function jwt_secret() { return dp_config()['jwt_secret']; }
function b64u($s) { return rtrim(strtr(base64_encode($s), '+/', '-_'), '='); }
function jwt_generate(array $payload, $secret) {
    $h = b64u(json_encode(['typ' => 'JWT', 'alg' => 'HS256']));
    $p = b64u(json_encode($payload));
    return "$h.$p." . b64u(hash_hmac('sha256', "$h.$p", $secret, true));
}
function jwt_verify($token, $secret) {
    $parts = explode('.', $token);
    if (count($parts) !== 3) return false;
    [$h, $p, $s] = $parts;
    if (!hash_equals(b64u(hash_hmac('sha256', "$h.$p", $secret, true)), $s)) return false;
    $d = json_decode(base64_decode(strtr($p, '-_', '+/')), true);
    if (!is_array($d) || !isset($d['exp']) || $d['exp'] < time()) return false;
    return $d;
}
function issue_token(array $user) {
    return jwt_generate([
        'user_id' => (int)$user['id'], 'workspace_id' => (int)$user['workspace_id'],
        'role' => $user['role'], 'person_id' => $user['person_id'] !== null ? (int)$user['person_id'] : null,
        'name' => $user['display_name'], 'email' => $user['email'],
        'exp' => time() + 7 * 86400, 'ver' => 1,
    ], jwt_secret());
}
