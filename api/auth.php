<?php
// Sign-in and account roles (ADM-01, ADM-02). Actions:
//   providers                 -> which identity providers this deployment offers (no token)
//   google_login {id_token}   -> {token, user}; creates the account on first sign-in
//   oidc_login {id_token}     -> the same for Entra ID, when 'entra' is configured
//   me (Bearer)               -> current user profile
//   list_users (team_lead)    -> the workspace's accounts, for Settings
//   set_role {user_id, role}  -> change somebody's role (admin)
//
// There are no local passwords and no development sign-in: an account exists because somebody signed
// in with an identity the workspace accepts. Google is the provider in use; the Entra path is kept
// verified and ready for the tenant to be configured, and `providers` is what tells the client which
// buttons to draw, so nothing is hard-coded in the app.
//
// Provisioning (ADM-03) happens on first sign-in rather than ahead of time: the first email listed in
// `bootstrap_admins` to arrive becomes an administrator, everybody else joins as a team member and is
// linked to the person record with the same work address if there is one. A deactivated account is
// refused rather than re-created — that is what deactivating a leaver is for.
require_once __DIR__ . '/db_connect.php';
require_once __DIR__ . '/jwt_lib.php';    // issue_token(); auth_middleware.php loads it too, but the
require_once __DIR__ . '/oidc_lib.php';   // sign-in branches below return before that is required.
$action = param('action', 'me');
$cfg = dp_config();

if ($action === 'providers') {
    $g = $cfg['google'] ?? [];
    $ids = array_values(array_filter((array)($g['client_ids'] ?? [])));
    $e = $cfg['entra'] ?? [];
    ok([
        // The web client id is the first one listed, by convention documented in config.example.php:
        // the browser needs it to start the flow, and the mobile apps send it as their server client
        // id so the token they get back is addressed to the same audience this API checks.
        'google' => ['enabled' => !empty($ids), 'web_client_id' => $ids[0] ?? null, 'hosted_domain' => ($g['hosted_domain'] ?? '') ?: null],
        'microsoft' => ['enabled' => !empty($e['tenant_id']) && !empty($e['client_id'])],
    ]);
}

if ($action === 'google_login') {
    $g = $cfg['google'] ?? [];
    if (empty($g['client_ids'])) fail('Google sign-in is not configured', 501);
    $claims = oidc_verify(require_param('id_token'), google_oidc_opts($g));
    if (!$claims) fail('ID token could not be verified', 401);
    $problem = google_claims_problem($claims, $g);
    if ($problem) fail($problem, 403);
    ok(sign_in_with($conn, strtolower(trim((string)$claims['email'])), (string)($claims['name'] ?? ''), 'google', 'google:' . ($claims['sub'] ?? ''), $cfg, (int)($g['workspace_id'] ?? 1)));
}

if ($action === 'oidc_login') {
    $entra = $cfg['entra'] ?? [];
    if (empty($entra['tenant_id']) || empty($entra['client_id'])) fail('Entra ID sign-in is not configured', 501);
    $claims = oidc_verify(require_param('id_token'), entra_oidc_opts($entra));
    if (!$claims) fail('ID token could not be verified', 401);
    $email = strtolower((string)($claims['preferred_username'] ?? $claims['email'] ?? ''));
    if ($email === '') fail('That account did not share an email address', 403);
    $r = sign_in_with($conn, $email, (string)($claims['name'] ?? ''), 'entra', (string)($claims['oid'] ?? ''), $cfg, (int)($entra['workspace_id'] ?? 1));
    // Entra group claims can raise a role but never lower one: the directory says what somebody is
    // entitled to, the workspace may have given them more.
    $u = row($conn, "SELECT * FROM dbo.users WHERE id = ?", [$r['user']['id']]);
    $best = $u['role'];
    foreach ((array)($claims['groups'] ?? []) as $grp) {
        $mapped = $entra['group_roles'][$grp] ?? null;
        if ($mapped && (DP_ROLE_RANK[$mapped] ?? 0) > (DP_ROLE_RANK[$best] ?? 0)) $best = $mapped;
    }
    if ($best !== $u['role']) {
        update($conn, 'users', ['role' => $best], 'id = ?', [$u['id']]);
        $u['role'] = $best;
        $r = ['token' => issue_token($u), 'user' => user_public($conn, $u)];
    }
    ok($r);
}

require_once __DIR__ . '/auth_middleware.php';

if ($action === 'me') {
    $u = row($conn, "SELECT * FROM dbo.users WHERE id = ?", [$userId]);
    ok(['user' => user_public($conn, $u)]);
}

if ($action === 'list_users') {
    // Who is in the workspace is not a secret — Settings is already a team-lead page, and
    // these are work addresses that appear on people records anyway. Changing somebody's
    // role is the administrator's job; seeing who holds which is not.
    require_role('team_lead');
    $out = [];
    foreach (rows($conn, "SELECT u.*, p.name AS person_name, p.initials, p.colour, p.role_title, t.name AS team_name
                          FROM dbo.users u LEFT JOIN dbo.people p ON p.id = u.person_id LEFT JOIN dbo.teams t ON t.id = p.team_id
                          WHERE u.workspace_id = ?
                          ORDER BY CASE u.role WHEN 'admin' THEN 0 WHEN 'delivery_lead' THEN 1 WHEN 'team_lead' THEN 2 ELSE 3 END, u.display_name", [$wsId]) as $u) {
        $out[] = ['id' => (int)$u['id'], 'email' => $u['email'], 'display_name' => $u['display_name'], 'short_name' => $u['short_name'],
            'role' => $u['role'], 'active' => (bool)$u['active'], 'auth_provider' => $u['auth_provider'],
            'person_id' => $u['person_id'] !== null ? (int)$u['person_id'] : null, 'person_name' => $u['person_name'],
            'initials' => $u['initials'] !== null ? trim((string)$u['initials']) : null, 'colour' => $u['colour'],
            'role_title' => $u['role_title'], 'team_name' => $u['team_name'], 'created_at' => $u['created_at']];
    }
    ok(['users' => $out, 'roles' => array_keys(DP_ROLE_RANK)]);
}

if ($action === 'set_role') {
    require_role('admin');
    $targetId = (int)require_param('user_id');
    $newRole = (string)require_param('role');
    if (!isset(DP_ROLE_RANK[$newRole])) fail('Unknown role: ' . $newRole, 400, ['roles' => array_keys(DP_ROLE_RANK)]);
    $u = row($conn, "SELECT * FROM dbo.users WHERE id = ? AND workspace_id = ?", [$targetId, $wsId]);
    if (!$u) fail('User not found', 404);
    // Locking every administrator out of a workspace is not recoverable from inside the product.
    if ($targetId === $userId && $newRole !== 'admin') {
        $others = (int)scalar($conn, "SELECT COUNT(*) FROM dbo.users WHERE workspace_id = ? AND role = 'admin' AND active = 1 AND id <> ?", [$wsId, $userId]);
        if ($others === 0) fail('You are the only administrator; promote somebody else first', 409);
    }
    if ($u['role'] !== $newRole) update($conn, 'users', ['role' => $newRole], 'id = ?', [$targetId]);
    audit($conn, $wsId, 'update', 'user', $targetId, ['role' => $u['role']], ['role' => $newRole], $u['display_name'], param('reason'));
    $after = row($conn, "SELECT * FROM dbo.users WHERE id = ?", [$targetId]);
    ok(['user' => user_public($conn, $after)]);
}

fail('Unknown action', 400);

// ---------------------------------------------------------------------------------------------------

/**
 * Find or create the account for a verified identity, and issue a token for it.
 * Returns ['token' => ..., 'user' => ...] ready to hand back.
 */
function sign_in_with($conn, $email, $displayName, $provider, $directoryObjectId, array $cfg, $workspaceId) {
    if ($email === '') fail('That account did not share an email address', 403);
    $ws = row($conn, "SELECT id FROM dbo.workspaces WHERE id = ?", [$workspaceId]);
    if (!$ws) fail('This deployment has no workspace to sign in to', 500);
    $bootstrap = array_map('strtolower', array_map('trim', (array)($cfg['bootstrap_admins'] ?? [])));
    $isBootstrap = in_array($email, $bootstrap, true);

    $u = row($conn, "SELECT * FROM dbo.users WHERE workspace_id = ? AND LOWER(email) = ?", [$workspaceId, $email]);
    if ($u && !(int)$u['active']) fail('That account has been deactivated', 401);

    if (!$u) {
        $name = trim($displayName) !== '' ? trim($displayName) : ucfirst((string)strstr($email, '@', true));
        $personId = scalar($conn, "SELECT id FROM dbo.people WHERE workspace_id = ? AND LOWER(email) = ? AND active = 1", [$workspaceId, $email]);
        $id = insert($conn, 'users', [
            'workspace_id' => $workspaceId, 'email' => $email,
            'display_name' => mb_substr($name, 0, 120), 'short_name' => short_name_for($name),
            'role' => $isBootstrap ? 'admin' : 'team_member',
            'person_id' => $personId !== null ? (int)$personId : null,
            'directory_object_id' => $directoryObjectId !== '' ? mb_substr($directoryObjectId, 0, 64) : null,
            'auth_provider' => $provider, 'active' => 1,
        ]);
        $u = row($conn, "SELECT * FROM dbo.users WHERE id = ?", [$id]);
        // audit() reads the acting user from globals, and the middleware has not run on this path —
        // the new account is both the actor and the subject of its own creation.
        $GLOBALS['userId'] = $id; $GLOBALS['userName'] = $u['display_name'];
        audit($conn, $workspaceId, 'create', 'user', $id, null,
            ['email' => $email, 'role' => $u['role'], 'auth_provider' => $provider, 'person_id' => $u['person_id']],
            $u['display_name'], $isBootstrap ? 'First sign-in; listed in bootstrap_admins' : 'First sign-in');
    } else {
        $GLOBALS['userId'] = (int)$u['id']; $GLOBALS['userName'] = $u['display_name'];
        $fill = [];
        if ($u['auth_provider'] !== $provider) $fill['auth_provider'] = $provider;
        if (empty($u['directory_object_id']) && $directoryObjectId !== '') $fill['directory_object_id'] = mb_substr($directoryObjectId, 0, 64);
        if ($u['person_id'] === null) {
            $personId = scalar($conn, "SELECT id FROM dbo.people WHERE workspace_id = ? AND LOWER(email) = ? AND active = 1", [$workspaceId, $email]);
            if ($personId !== null) $fill['person_id'] = (int)$personId;
        }
        if ($isBootstrap && $u['role'] !== 'admin') $fill['role'] = 'admin';
        if ($fill) {
            update($conn, 'users', $fill, 'id = ?', [$u['id']]);
            if (isset($fill['role'])) audit($conn, $workspaceId, 'update', 'user', (int)$u['id'], ['role' => $u['role']], ['role' => 'admin'], $u['display_name'], 'Listed in bootstrap_admins');
            $u = row($conn, "SELECT * FROM dbo.users WHERE id = ?", [$u['id']]);
        }
    }
    return ['token' => issue_token($u), 'user' => user_public($conn, $u)];
}

/** 'Ben Andrew Stevenson' -> 'Ben S.'; a single word is left alone. */
function short_name_for($name) {
    $parts = preg_split('/\s+/', trim($name), -1, PREG_SPLIT_NO_EMPTY);
    if (!$parts) return null;
    if (count($parts) === 1) return mb_substr($parts[0], 0, 40);
    return mb_substr($parts[0] . ' ' . mb_substr(end($parts), 0, 1) . '.', 0, 40);
}

function user_public($conn, $u) {
    $p = $u['person_id'] ? row($conn, "SELECT id, name, initials, colour, role_title, team_id FROM dbo.people WHERE id = ?", [$u['person_id']]) : null;
    $ws = row($conn, "SELECT id, name, time_zone, working_days, hours_per_day, currency FROM dbo.workspaces WHERE id = ?", [$u['workspace_id']]);
    return ['id' => (int)$u['id'], 'email' => $u['email'], 'display_name' => $u['display_name'], 'short_name' => $u['short_name'],
        'role' => $u['role'], 'auth_provider' => $u['auth_provider'] ?? null,
        'person_id' => $u['person_id'] !== null ? (int)$u['person_id'] : null, 'person' => $p, 'workspace' => $ws];
}
