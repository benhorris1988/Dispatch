<?php
// Sign-in. Actions:
//   list_dev_users            -> seeded users to pick from (dev only)
//   dev_login {user_id}       -> token (dev only; production uses Entra ID OIDC)
//   oidc_login {id_token}     -> token, when 'entra' is configured
//   me (Bearer)               -> current user profile
require_once __DIR__ . '/db_connect.php';
// issue_token() lives here. auth_middleware.php also loads it, but that is required
// further down — the dev_login and oidc_login branches return before reaching it.
require_once __DIR__ . '/jwt_lib.php';
$action = param('action', 'me');
$cfg = dp_config();

if ($action === 'list_dev_users') {
    if (empty($cfg['dev_login_enabled'])) fail('Dev sign-in is disabled', 403);
    ok(['users' => rows($conn, "SELECT u.id, u.display_name, u.short_name, u.email, u.role, u.person_id, p.role_title, p.initials, p.colour, w.name AS workspace
        FROM dbo.users u JOIN dbo.workspaces w ON w.id=u.workspace_id LEFT JOIN dbo.people p ON p.id=u.person_id WHERE u.active=1
        ORDER BY CASE u.role WHEN 'delivery_lead' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END, u.display_name")]);
}
if ($action === 'dev_login') {
    if (empty($cfg['dev_login_enabled'])) fail('Dev sign-in is disabled', 403);
    $u = row($conn, "SELECT * FROM dbo.users WHERE id = ? AND active = 1", [(int)require_param('user_id')]);
    if (!$u) fail('Unknown user', 404);
    ok(['token' => issue_token($u), 'user' => user_public($conn, $u)]);
}
if ($action === 'oidc_login') {
    $entra = $cfg['entra'] ?? [];
    if (empty($entra['tenant_id']) || empty($entra['client_id'])) fail('Entra ID sign-in is not configured', 501);
    $claims = oidc_verify(require_param('id_token'), $entra);
    if (!$claims) fail('ID token could not be verified', 401);
    $email = strtolower($claims['preferred_username'] ?? $claims['email'] ?? '');
    $u = row($conn, "SELECT * FROM dbo.users WHERE LOWER(email) = ? AND active = 1", [$email]);
    if (!$u) fail('No Dispatch account for this identity', 403);
    $best = $u['role'];
    foreach ((array)($claims['groups'] ?? []) as $g) {
        $r = $entra['group_roles'][$g] ?? null;
        if ($r && (DP_ROLE_RANK[$r] ?? 0) > (DP_ROLE_RANK[$best] ?? 0)) $best = $r;
    }
    if ($best !== $u['role']) { update($conn, 'users', ['role' => $best], 'id = ?', [$u['id']]); $u['role'] = $best; }
    if (!empty($claims['oid'])) update($conn, 'users', ['directory_object_id' => $claims['oid']], 'id = ?', [$u['id']]);
    ok(['token' => issue_token($u), 'user' => user_public($conn, $u)]);
}
require_once __DIR__ . '/auth_middleware.php';
if ($action === 'me') {
    $u = row($conn, "SELECT * FROM dbo.users WHERE id = ?", [$userId]);
    ok(['user' => user_public($conn, $u)]);
}
fail('Unknown action', 400);

function user_public($conn, $u) {
    $p = $u['person_id'] ? row($conn, "SELECT id, name, initials, colour, role_title, team_id FROM dbo.people WHERE id = ?", [$u['person_id']]) : null;
    $ws = row($conn, "SELECT id, name, time_zone, working_days, hours_per_day, currency FROM dbo.workspaces WHERE id = ?", [$u['workspace_id']]);
    return ['id' => (int)$u['id'], 'email' => $u['email'], 'display_name' => $u['display_name'], 'short_name' => $u['short_name'],
        'role' => $u['role'], 'person_id' => $u['person_id'] !== null ? (int)$u['person_id'] : null, 'person' => $p, 'workspace' => $ws];
}
/** Verify an Entra ID token: RS256 signature via the tenant JWKS, iss/aud/exp. */
function oidc_verify($jwt, array $entra) {
    $parts = explode('.', $jwt); if (count($parts) !== 3) return null;
    $hdr = json_decode(base64_decode(strtr($parts[0], '-_', '+/')), true);
    $claims = json_decode(base64_decode(strtr($parts[1], '-_', '+/')), true);
    if (!$hdr || !$claims || ($hdr['alg'] ?? '') !== 'RS256') return null;
    if (($claims['exp'] ?? 0) < time()) return null;
    if (($claims['aud'] ?? '') !== $entra['client_id']) return null;
    $tenant = $entra['tenant_id'];
    if (strpos($claims['iss'] ?? '', $tenant) === false) return null;
    $jwks = json_decode(@file_get_contents("https://login.microsoftonline.com/$tenant/discovery/v2.0/keys"), true);
    foreach ($jwks['keys'] ?? [] as $k) {
        if (($k['kid'] ?? '') !== ($hdr['kid'] ?? '')) continue;
        $pem = "-----BEGIN CERTIFICATE-----\n" . chunk_split($k['x5c'][0], 64, "\n") . "-----END CERTIFICATE-----\n";
        $pub = openssl_pkey_get_public($pem); if (!$pub) return null;
        $sig = base64_decode(strtr($parts[2], '-_', '+/'));
        return openssl_verify("$parts[0].$parts[1]", $sig, $pub, OPENSSL_ALGO_SHA256) === 1 ? $claims : null;
    }
    return null;
}
